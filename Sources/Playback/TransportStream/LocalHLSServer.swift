import Foundation
import Network
import os

/// A loopback HTTP server that publishes segments from `TSSegmenter` as a live
/// HLS playlist.
///
/// **Why a server and not an `AVAssetResourceLoaderDelegate`.** The delegate
/// route is the "supported" way to feed AVFoundation bytes it cannot fetch
/// itself, and for HLS it is a trap: adopting it for a playlist means taking
/// over playlist *and* segment loading, reimplementing live-edge tracking and
/// reload timing by hand, against an interface with almost no error reporting.
/// A socket on 127.0.0.1 lets AVFoundation use the HLS client Apple already
/// wrote and tests — the one that handles live windows, sequence rollover and
/// buffering — and our side stays a few hundred bytes of HTTP.
///
/// The cost is one listening socket, bound to loopback so it is not reachable
/// off-device.
actor LocalHLSServer {
    enum ServerError: Error, LocalizedError {
        case listenerFailed(String)
        case noPort

        var errorDescription: String? {
            switch self {
            case let .listenerFailed(reason): "Local stream server failed to start: \(reason)"
            case .noPort: "Local stream server started without a port"
            }
        }
    }

    private static let log = Logger(subsystem: "com.soosh.viewer", category: "LocalHLSServer")

    /// How many segments stay in the live window.
    ///
    /// Ten at ~2.5s is a ~25s window, about 19MB of segment data at this
    /// bitrate. It has to comfortably exceed the three target durations a live
    /// client sits behind the end, or the player is chasing a segment that has
    /// already been evicted.
    ///
    /// **Raised from six after a Catalyst report.** The upstream keeps running
    /// while the app is occluded, so anything that stalls playback for longer
    /// than the window evicts the segment the player wants next. Twenty-five
    /// seconds covers a glance at another app, so that case resumes seamlessly
    /// instead of jumping. `LiveEdgePolicy` handles the longer absences that no
    /// sane window size would cover — which is why this is 10 and not 100.
    private let windowSize = 10

    private var listener: NWListener?
    private var segments: [TSSegment] = []

    /// `EXT-X-TARGETDURATION` for the playlist as it stands.
    ///
    /// **Computed from the current window, never ratcheted.** This was a
    /// monotonic maximum over every segment ever produced, on the reasoning that
    /// target duration is a promise no segment exceeds. That reading is wrong,
    /// and it cost a bug that took twenty minutes of viewing to show up: the
    /// promise is about the segments *in the playlist*, and the playlist only
    /// ever holds this window.
    ///
    /// What the ratchet did, measured: one 8s segment — the `maxSegmentDuration`
    /// safety valve firing once, or any hiccup — raised the target from 3 to 8
    /// permanently. A live client may not seek within three target durations of
    /// the end, so the seekable span collapsed from 16s to 1s against a 25s
    /// window and stayed there. Playback sat on the eviction boundary and
    /// rebuffered continuously, and only a new session cleared it, which is why
    /// changing channel appeared to fix it.
    ///
    /// **The invariant to preserve:** the window must comfortably exceed three
    /// times the longest segment it can hold. See `windowSize` and
    /// `TSSegmenter.maxSegmentDuration`.
    private var targetDuration: Int {
        let longest = segments.map(\.duration).max() ?? 0
        return max(1, Int(longest.rounded(.up)))
    }

    /// Highest index published, so a straggler cannot reorder the window.
    private var lastPublishedIndex = -1

    private(set) var port: UInt16?

    /// A session-unique path prefix.
    ///
    /// The port is reused across sessions by the OS, and AVFoundation caches
    /// aggressively by URL. Without a fresh path each session, channel two can
    /// be served channel one's playlist out of cache.
    private let token = UUID().uuidString

    private let queue = DispatchQueue(label: "com.soosh.viewer.hls-server")

    init() {}

    // MARK: - Lifecycle

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        // Loopback only. `NWListener` would otherwise bind every interface,
        // which would put the raw stream on the local network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ServerError.listenerFailed(error.localizedDescription)
        }

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            Task { await self?.handle(connection) }
        }

        listener.start(queue: queue)

        // `listener.port` is populated synchronously on start for an .any port,
        // but the state machine is asynchronous; poll briefly rather than
        // assuming either way.
        for _ in 0 ..< 200 {
            if let resolved = listener.port?.rawValue, resolved != 0 {
                self.listener = listener
                port = resolved
                return resolved
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        listener.cancel()
        throw ServerError.noPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        segments.removeAll()
        lastPublishedIndex = -1
        port = nil
    }

    /// URL to hand to AVPlayer.
    func playlistURL() throws -> URL {
        guard let port else { throw ServerError.noPort }
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/live.m3u8") else {
            throw ServerError.noPort
        }
        return url
    }

    // MARK: - Publishing

    func publish(_ segment: TSSegment) {
        // **Out-of-order publishes are dropped rather than appended.**
        // `EXT-X-MEDIA-SEQUENCE` is read from the first segment in the window and
        // a client treats it as monotonic; letting a straggler in makes the
        // sequence go backwards and evicts the wrong end of the window. The
        // caller is ordered now, so this should never fire — it is here because
        // it *used* to, and the failure it produced was silent.
        guard segment.index > lastPublishedIndex else {
            Self.log.error("out-of-order segment \(segment.index) after \(self.lastPublishedIndex), dropped")
            return
        }
        lastPublishedIndex = segment.index

        segments.append(segment)
        if segments.count > windowSize {
            segments.removeFirst(segments.count - windowSize)
        }
    }

    var segmentCount: Int { segments.count }

    /// Whether the window holds enough for a live client to start.
    ///
    /// **A live client begins three target durations back from the end**, so a
    /// playlist shorter than that gives it nowhere to start: it loads, waits for
    /// the window to grow, and produces no frame in the meantime. Handing over
    /// two segments and hoping was worth ~13.5s to first frame on a channel
    /// measured here — long enough for `PlayerModel`'s 6s stall timeout to fire,
    /// retry, and open another upstream connection, which reads to the user as
    /// loading forever.
    ///
    /// The extra segment on top is headroom, so the start point is inside the
    /// window rather than exactly on its edge.
    var hasPlayableWindow: Bool {
        guard let longest = segments.map(\.duration).max(), longest > 0 else { return false }
        let windowDuration = segments.reduce(0) { $0 + $1.duration }
        return windowDuration >= 3 * Double(targetDuration) + longest
    }

    // MARK: - Playlist

    private func playlist() -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(segments.first?.index ?? 0)",
        ]

        // **No `EXT-X-START`.** There was one here asking to begin a single
        // target duration back, as a join-latency knob. It never worked: HLS
        // requires a live start point at least three target durations from the
        // end, so AVFoundation rejected it every time and fell back to the
        // default. The only thing it produced was a permanent
        // `-16831 START-TIME is too close to live` in the player's error log,
        // which is noise that hides real faults.
        //
        // Three target durations back is therefore where playback starts, and
        // `TSRewrapSession` waits for the window to actually contain that much
        // before handing the playlist over — see `minimumPlayableWindow`.

        for segment in segments {
            if segment.isDiscontinuous {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            lines.append("#EXTINF:\(String(format: "%.3f", segment.duration)),")
            // **Relative to the playlist, which already sits under the token.**
            // Writing the token in here as well resolves to `/token/token/s/0.ts`
            // — the playlist parses, every segment 404s, and the player waits
            // forever on a live stream that never delivers a byte.
            lines.append("s/\(segment.index).ts")
        }

        // **No `#EXT-X-ENDLIST`.** Its absence is what makes this a live
        // playlist: the client keeps reloading and following the window instead
        // of treating the last segment as the end of the programme.
        return lines.joined(separator: "\n") + "\n"
    }

    private func segmentData(index: Int) -> Data? {
        segments.first { $0.index == index }?.data
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) async {
        defer { connection.cancel() }

        guard let request = await readRequestLine(connection) else { return }
        guard let path = Self.requestPath(request) else {
            await send(connection, status: "400 Bad Request", contentType: "text/plain", body: Data())
            return
        }

        // Every route is namespaced by the session token, so a stale URL from a
        // previous channel cannot resolve against this session's segments.
        guard path.hasPrefix("/\(token)/") else {
            await send(connection, status: "404 Not Found", contentType: "text/plain", body: Data())
            return
        }
        let route = String(path.dropFirst(token.count + 2))

        if route == "live.m3u8" {
            let body = Data(playlist().utf8)
            await send(
                connection,
                status: "200 OK",
                contentType: "application/vnd.apple.mpegurl",
                body: body
            )
        } else if route.hasPrefix("s/"), route.hasSuffix(".ts"),
                  let index = Int(route.dropFirst(2).dropLast(3)) {
            if let data = segmentData(index: index) {
                await send(connection, status: "200 OK", contentType: "video/mp2t", body: data)
            } else {
                // Evicted from the window. A 404 is the correct answer and the
                // client recovers by reloading the playlist.
                Self.log.debug("segment \(index) requested after eviction")
                await send(connection, status: "404 Not Found", contentType: "text/plain", body: Data())
            }
        } else {
            await send(connection, status: "404 Not Found", contentType: "text/plain", body: Data())
        }
    }

    /// Reads until the end of the request headers.
    ///
    /// Requests here are AVFoundation's own GETs — no bodies, a few hundred
    /// bytes — so this stops at the header terminator and never looks further.
    private func readRequestLine(_ connection: NWConnection) async -> String? {
        var buffer = Data()
        for _ in 0 ..< 16 {
            guard let chunk = await connection.receiveChunk(), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if buffer.count > 8192 { break }
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                return text
            }
        }
        return String(data: buffer, encoding: .utf8)
    }

    private nonisolated static func requestPath(_ request: String) -> String? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private func send(_ connection: NWConnection, status: String, contentType: String, body: Data) async {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        // The playlist changes every target duration; nothing here may be
        // cached, least of all by AVFoundation's own URL cache.
        header += "Cache-Control: no-cache, no-store\r\n"
        header += "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(body)
        await connection.sendAll(payload)
    }
}

// MARK: - Continuation bridges

/// `NWConnection`'s callbacks predate async/await; these are the two bridges
/// this file needs, kept together so the resume-exactly-once reasoning is in
/// one place rather than scattered through the request handler.
private extension NWConnection {
    func receiveChunk() async -> Data? {
        await withCheckedContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    func sendAll(_ data: Data) async {
        await withCheckedContinuation { continuation in
            send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

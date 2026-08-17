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

    /// The largest `EXT-X-TARGETDURATION` announced so far.
    ///
    /// **Only ever raised.** Target duration is a promise that no segment
    /// exceeds it; lowering it after a long segment retroactively breaks that
    /// promise, and clients respond by stalling rather than complaining.
    private var announcedTarget = 1

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
        segments.append(segment)
        announcedTarget = max(announcedTarget, Int(segment.duration.rounded(.up)))
        if segments.count > windowSize {
            segments.removeFirst(segments.count - windowSize)
        }
    }

    var segmentCount: Int { segments.count }

    // MARK: - Playlist

    private func playlist() -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(announcedTarget)",
            "#EXT-X-MEDIA-SEQUENCE:\(segments.first?.index ?? 0)",
        ]

        // Start playback near the live edge instead of the default three target
        // durations back.
        //
        // This is the join-latency knob. A segment cannot be shorter than the
        // GOP (~2.5s here), so the default start point means waiting for three
        // of them — ~7.5s of accumulation before the first frame. One segment
        // back is live television's actual expectation. If channels turn out to
        // rebuffer on join, this is the first number to make more negative.
        lines.append("#EXT-X-START:TIME-OFFSET=-\(String(format: "%.3f", Double(announcedTarget))),PRECISE=NO")

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

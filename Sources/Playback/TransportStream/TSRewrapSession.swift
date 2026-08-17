import Foundation
import os

/// Holds one upstream MPEG-TS connection open, segments it, and serves the
/// result as live HLS on loopback.
///
/// This is the whole of what used to require FFmpeg. Dispatcharr's
/// `/proxy/ts/stream/` is an endless TS body; AVFoundation will not consume one
/// directly, but it decodes MPEG-TS happily as HLS segments. So the session
/// stands between them: one socket up to the server, one playlist down to
/// AVPlayer, and no decoding anywhere in between.
///
/// **One upstream connection per session, and that is a guarantee, not a
/// coincidence.** AVFoundation re-fetches a live playlist every target duration
/// and pulls segments alongside it, which against the real server read as
/// several concurrent clients and burned the provider's connection slots. All
/// that chatter now terminates on 127.0.0.1.
actor TSRewrapSession {
    private static let log = Logger(subsystem: "com.soosh.viewer", category: "TSRewrap")

    /// How many times a dropped upstream is re-dialled before giving up.
    ///
    /// Bounded for the reason the old engine's `liveSourceReset` was bounded: a
    /// provider that is refusing us will keep refusing us, and an unbounded
    /// retune loop against it is indistinguishable from a channel that is merely
    /// slow — while still consuming a connection slot on every attempt.
    private static let maxReconnects = 3

    private let upstreamURL: URL
    private let headers: [String: String]
    private let server = LocalHLSServer()

    private var segmenter = TSSegmenter()
    private var urlSession: URLSession?
    private var currentTask: URLSessionDataTask?
    private var pumpTask: Task<Void, Never>?
    private var stopped = false

    /// Latest upstream failure, for the engine to surface. Nil while healthy.
    private(set) var lastError: String?

    private var byteCount = 0

    init(upstreamURL: URL, headers: [String: String]) {
        self.upstreamURL = upstreamURL
        self.headers = headers
    }

    // MARK: - Lifecycle

    /// Starts the server and the upstream pump, and returns the loopback
    /// playlist URL once enough of a live window exists to play.
    ///
    /// Waiting here rather than returning immediately is deliberate: handing
    /// AVPlayer a playlist with no segments in it makes it fail the item
    /// outright instead of retrying, and the failure reads as a broken stream
    /// rather than one that has not started yet.
    func start(minimumSegments: Int = 2, timeout: Duration = .seconds(20)) async throws -> URL {
        _ = try await server.start()

        pumpTask = Task { [weak self] in
            await self?.pump()
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await server.segmentCount >= minimumSegments {
                return try await server.playlistURL()
            }
            if let lastError, currentTask == nil {
                throw RewrapError.upstreamFailed(lastError)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw RewrapError.timedOut
    }

    func stop() async {
        stopped = true
        pumpTask?.cancel()
        pumpTask = nil
        currentTask?.cancel()
        currentTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        await server.stop()
    }

    enum RewrapError: Error, LocalizedError {
        case upstreamFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case let .upstreamFailed(reason): reason
            case .timedOut: "The channel did not start streaming in time."
            }
        }
    }

    // MARK: - Upstream

    private func pump() async {
        var attempt = 0

        while !stopped, attempt <= Self.maxReconnects {
            let bytesBefore = byteCount
            await runOneConnection()
            if stopped { return }

            // A connection that actually delivered video is not a failed
            // attempt — it is a live stream that dropped. Resetting the count
            // means a channel can run all day across occasional drops without
            // spending its retry budget on the first few hours.
            if byteCount > bytesBefore + 1_000_000 {
                attempt = 0
            } else {
                attempt += 1
            }

            guard attempt <= Self.maxReconnects else { break }

            segmenter.noteReconnect()
            Self.log.notice("upstream dropped, reconnecting (attempt \(attempt))")
            try? await Task.sleep(for: .milliseconds(500))
        }

        if !stopped {
            lastError = lastError ?? "The channel stopped sending data."
            Self.log.error("upstream gave up after \(Self.maxReconnects) reconnects")
        }
    }

    private func runOneConnection() async {
        var request = URLRequest(url: upstreamURL)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // The body never ends, so a resource timeout would eventually kill a
        // perfectly healthy channel. The request timeout still applies to the
        // *response headers*, which is the part that can legitimately hang.
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        // Chunks arrive on the delegate and are handed over through an
        // AsyncStream rather than a `Task { await … }` per callback.
        //
        // **That detail is load-bearing.** Unstructured tasks are not ordered
        // with respect to each other, so a task per chunk would let two socket
        // reads reach the segmenter out of order and interleave garbage into the
        // middle of a segment. An AsyncStream preserves yield order.
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let delegate = UpstreamDelegate(continuation: continuation)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.networkServiceType = .video
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        urlSession = session

        let task = session.dataTask(with: request)
        currentTask = task
        task.resume()

        for await chunk in stream {
            guard !stopped else { break }
            ingest(chunk)
        }

        if let error = delegate.failure {
            lastError = error
        }
        currentTask = nil
        session.invalidateAndCancel()
        urlSession = nil
    }

    private func ingest(_ chunk: Data) {
        byteCount += chunk.count
        let produced = segmenter.append(chunk)
        guard !produced.isEmpty else { return }
        Task { [server] in
            for segment in produced {
                await server.publish(segment)
            }
        }
    }
}

/// Bridges `URLSessionDataDelegate` callbacks into an `AsyncStream`.
///
/// `@unchecked Sendable` because the only mutable state is `failure`, written
/// once on the delegate queue at completion and read after the stream has
/// finished — the continuation itself is documented as thread-safe.
private final class UpstreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private(set) var failure: String?

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data)
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // A Dispatcharr refusal — an exhausted provider slot, an unknown UUID —
        // arrives as a normal HTTP error with a body, not a transport failure.
        // Without this check those bodies would be fed to the segmenter as if
        // they were video, and the symptom would be a channel that connects and
        // never produces a segment.
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            failure = "The server refused the stream (HTTP \(http.statusCode))."
            completionHandler(.cancel)
            continuation.finish()
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            failure = error.localizedDescription
        }
        continuation.finish()
    }
}

import Foundation
import Testing

@testable import Soosh

/// Tests for the loopback HLS server.
///
/// **These exist because of one bug that cost a debugging session.** The
/// playlist wrote its segment URIs with the session token in them, forgetting
/// that they resolve *relative to the playlist*, which already sits under the
/// token. Every segment URL came out as `/token/token/s/0.ts` and 404'd.
///
/// Nothing upstream of the player noticed. The playlist parsed, the server was
/// healthy, the segmenter was correct, and the only symptom was a channel that
/// loaded forever. So the thing worth asserting is not "the playlist looks
/// right" but **"a client that resolves these URIs the way HLS says to can
/// actually fetch them"** — which is what the second test does.
@Suite("Local HLS server")
struct LocalHLSServerTests {
    /// A minimal well-formed segment. The server never parses these, it only
    /// stores and serves them, so the bytes only have to be distinguishable.
    private func makeSegment(index: Int, duration: TimeInterval = 2.5) -> TSSegment {
        TSSegment(
            index: index,
            data: Data(repeating: UInt8(truncatingIfNeeded: index &+ 1), count: 512),
            duration: duration,
            isDiscontinuous: false
        )
    }

    @Test("the playlist is a live playlist, not a finished one")
    func playlistIsLive() async throws {
        let server = LocalHLSServer()
        _ = try await server.start()
        defer { Task { await server.stop() } }

        for index in 0 ..< 3 { await server.publish(makeSegment(index: index)) }

        let url = try await server.playlistURL()
        let (data, _) = try await URLSession.shared.data(from: url)
        let text = try #require(String(data: data, encoding: .utf8))

        // Its absence is the whole difference between live and video-on-demand:
        // with it, the player treats the last segment as the end of the
        // programme and stops instead of following the window.
        #expect(!text.contains("#EXT-X-ENDLIST"))
        #expect(text.contains("#EXTM3U"))
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        // Target duration is a promise no segment exceeds it.
        #expect(text.contains("#EXT-X-TARGETDURATION:3"))
    }

    @Test("segment URIs resolve to URLs the server actually serves")
    func segmentURIsResolve() async throws {
        let server = LocalHLSServer()
        _ = try await server.start()
        defer { Task { await server.stop() } }

        for index in 0 ..< 3 { await server.publish(makeSegment(index: index)) }

        let playlistURL = try await server.playlistURL()
        let (data, _) = try await URLSession.shared.data(from: playlistURL)
        let text = try #require(String(data: data, encoding: .utf8))

        let uris = text.split(separator: "\n").filter { $0.hasSuffix(".ts") }
        #expect(uris.count == 3)

        for uri in uris {
            // Resolved exactly as an HLS client resolves a relative URI: against
            // the playlist's own URL. This is the step the bug fell through.
            let resolved = try #require(URL(string: String(uri), relativeTo: playlistURL)?.absoluteURL)
            let (segment, response) = try await URLSession.shared.data(from: resolved)
            let status = try #require((response as? HTTPURLResponse)?.statusCode)

            #expect(status == 200, "segment \(uri) resolved to \(resolved.path) and was not served")
            #expect(segment.count == 512)
        }
    }

    @Test("a segment evicted from the window is refused rather than mis-served")
    func evictedSegmentIsNotFound() async throws {
        let server = LocalHLSServer()
        _ = try await server.start()
        defer { Task { await server.stop() } }

        // Comfortably more than any sane window, so this does not have to be
        // edited every time the window is retuned.
        for index in 0 ..< 40 { await server.publish(makeSegment(index: index)) }

        let playlistURL = try await server.playlistURL()
        let evicted = try #require(URL(string: "s/0.ts", relativeTo: playlistURL)?.absoluteURL)
        let (_, response) = try await URLSession.shared.data(from: evicted)

        // 404 is the correct answer — the client recovers by reloading the
        // playlist. Serving the wrong segment would be far worse.
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }
}

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

/// Tests for the sliding window's timing invariants.
///
/// These exist because of a bug that only showed up after ~20 minutes of
/// viewing: `EXT-X-TARGETDURATION` was a monotonic maximum over every segment
/// ever produced, so one long segment raised it permanently. Since a live client
/// may not seek within three target durations of the end, the seekable span
/// collapsed against a fixed window and playback rebuffered continuously until
/// the session was restarted.
@Suite("Live window timing")
struct LiveWindowTimingTests {
    private func makeSegment(index: Int, duration: TimeInterval) -> TSSegment {
        TSSegment(
            index: index,
            data: Data(repeating: UInt8(truncatingIfNeeded: index), count: 256),
            duration: duration,
            isDiscontinuous: false
        )
    }

    private func targetDuration(of server: LocalHLSServer) async throws -> Int {
        let url = try await server.playlistURL()
        let (data, _) = try await URLSession.shared.data(from: url)
        let text = try #require(String(data: data, encoding: .utf8))
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("#EXT-X-TARGETDURATION:") })
        return try #require(Int(line.dropFirst("#EXT-X-TARGETDURATION:".count)))
    }

    @Test("target duration recovers once a long segment leaves the window")
    func targetDurationSelfHeals() async throws {
        let server = LocalHLSServer()
        _ = try await server.start()
        defer { Task { await server.stop() } }

        var index = 0
        for _ in 0 ..< 10 { await server.publish(makeSegment(index: index, duration: 2.5)); index += 1 }
        #expect(try await targetDuration(of: server) == 3)

        // One long segment: the safety valve firing, or any upstream hiccup.
        await server.publish(makeSegment(index: index, duration: 6)); index += 1
        #expect(try await targetDuration(of: server) == 6)

        // Once it has aged out of the window the promise no longer applies to it.
        for _ in 0 ..< 12 { await server.publish(makeSegment(index: index, duration: 2.5)); index += 1 }
        #expect(try await targetDuration(of: server) == 3, "target duration ratcheted and never recovered")
    }

    @Test("the window outlasts three target durations even at the worst segment length")
    func windowOutlastsThreeTargetDurations() async throws {
        let server = LocalHLSServer()
        _ = try await server.start()
        defer { Task { await server.stop() } }

        // The worst realistic mix: a full window of normal segments with one
        // safety-valve segment in it.
        var index = 0
        var total: TimeInterval = 0
        for _ in 0 ..< 9 {
            await server.publish(makeSegment(index: index, duration: 2.5)); index += 1
            total += 2.5
        }
        await server.publish(makeSegment(index: index, duration: TSSegmenter().maxSegmentDuration))
        total += TSSegmenter().maxSegmentDuration

        let target = TimeInterval(try await targetDuration(of: server))
        // A live client sits three target durations back. If that consumes the
        // window, playback lives on the eviction boundary and stutters forever.
        #expect(total - 3 * target > 5, "seekable span collapsed to \(total - 3 * target)s")
    }

    @Test("an out-of-order segment is dropped rather than walking the sequence backwards")
    func outOfOrderSegmentIsDropped() async throws {
        let server = LocalHLSServer()
        _ = try await server.start()
        defer { Task { await server.stop() } }

        for index in 0 ..< 5 { await server.publish(makeSegment(index: index, duration: 2.5)) }
        // A straggler from a racing publish. Accepting it would make
        // EXT-X-MEDIA-SEQUENCE non-monotonic for a client that already saw 4.
        await server.publish(makeSegment(index: 2, duration: 2.5))

        let url = try await server.playlistURL()
        let (data, _) = try await URLSession.shared.data(from: url)
        let text = try #require(String(data: data, encoding: .utf8))
        let uris = text.split(separator: "\n").filter { $0.hasSuffix(".ts") }
        #expect(uris == ["s/0.ts", "s/1.ts", "s/2.ts", "s/3.ts", "s/4.ts"])
    }
}

/// Tests for the handover gate.
///
/// A live client starts three target durations back from the end. Handing it a
/// playlist shorter than that gives it nowhere to begin: it loads, waits for the
/// window to grow, and shows nothing meanwhile. The session used to hand over
/// after two segments, which is well short of that.
@Suite("Playable window")
struct PlayableWindowTests {
    private func makeSegment(index: Int, duration: TimeInterval) -> TSSegment {
        TSSegment(index: index, data: Data(repeating: 0x47, count: 128),
                  duration: duration, isDiscontinuous: false)
    }

    @Test("an empty window is not playable")
    func emptyWindowIsNotPlayable() async throws {
        let server = LocalHLSServer()
        #expect(await server.hasPlayableWindow == false)
    }

    @Test("two segments are not enough to start a live stream")
    func twoSegmentsAreNotEnough() async throws {
        let server = LocalHLSServer()
        for index in 0 ..< 2 { await server.publish(makeSegment(index: index, duration: 2.5)) }
        // 5s of window against a 3s target: a client starting 9s back has
        // nowhere to go. This is the case that stalled the join.
        #expect(await server.hasPlayableWindow == false)
    }

    @Test("a window covering three target durations plus headroom is playable")
    func sufficientWindowIsPlayable() async throws {
        let server = LocalHLSServer()
        var index = 0
        // 2.5s segments -> target 3 -> needs 9s + 2.5s headroom = 11.5s.
        while await !server.hasPlayableWindow {
            await server.publish(makeSegment(index: index, duration: 2.5))
            index += 1
            #expect(index < 20, "never became playable")
        }
        #expect(index == 5)
    }

    @Test("the playlist advertises no EXT-X-START")
    func noStartTag() async throws {
        let server = LocalHLSServer()
        _ = try await server.start()
        defer { Task { await server.stop() } }
        for index in 0 ..< 6 { await server.publish(makeSegment(index: index, duration: 2.5)) }

        let url = try await server.playlistURL()
        let (data, _) = try await URLSession.shared.data(from: url)
        let text = try #require(String(data: data, encoding: .utf8))
        // A start point closer than three target durations is rejected outright
        // by AVFoundation ("START-TIME is too close to live"), so the tag only
        // ever produced error-log noise.
        #expect(!text.contains("#EXT-X-START"))
    }
}

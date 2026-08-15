import Foundation
import Testing

@testable import Soosh

/// A scriptable engine, so the connect loop can be exercised without a decoder
/// or a network. This is the whole reason `PlaybackEngine` survived the port.
@MainActor
final class FakeEngine: PlaybackEngine {
    /// Snapshots handed out in order; the last one repeats forever.
    var script: [PlaybackSnapshot]
    private var index = 0

    private(set) var openCount = 0
    private(set) var stopCount = 0
    /// Ordered log, so "stop ran before the retry" is checkable.
    private(set) var calls: [String] = []

    var openError: (any Error)?
    var lastError: String?
    var isPlaying = false

    init(script: [PlaybackSnapshot] = [PlaybackSnapshot()]) {
        self.script = script
    }

    func open(url: URL, headers: [String: String]) async throws {
        openCount += 1
        calls.append("open")
        if let openError { throw openError }
    }

    func stop() async {
        stopCount += 1
        calls.append("stop")
        index = 0
    }

    func playOrPause() {}

    var snapshot: PlaybackSnapshot {
        defer { index = min(index + 1, script.count - 1) }
        return script[min(index, script.count - 1)]
    }
}

@MainActor
private func makeModel(engine: FakeEngine) -> PlayerModel {
    PlayerModel(
        channelName: "Test",
        streamURL: URL(string: "https://example.test/stream")!,
        programs: [],
        engine: engine
    )
}

@Suite("Playback snapshot")
struct PlaybackSnapshotTests {

    @Test("a decoded frame counts as playing")
    func decodedFrameIsPlaying() {
        #expect(PlaybackSnapshot(width: 1920).isPlayingMedia)
    }

    @Test("an audio-only stream counts as playing once position moves")
    func audioOnlyNeedsPosition() {
        // Audio-only streams never report a width, so width alone would never
        // let them through.
        #expect(!PlaybackSnapshot(hasAudio: true, position: 0).isPlayingMedia)
        #expect(PlaybackSnapshot(hasAudio: true, position: 1.5).isPlayingMedia)
    }

    @Test("a video stream with audio running but no frame yet is not playing")
    func videoWithoutFrameIsNotPlaying() {
        // The regression this pins: a live channel joined mid-GOP has audio
        // advancing well before the first decodable video frame. Treating that
        // as success left the connect loop declaring victory on a black screen.
        // `hasAudio` must mean "this stream carries no video", not "no frame
        // has arrived yet".
        let audioRunningNoFrame = PlaybackSnapshot(
            width: nil, hasAudio: false, position: 3.0, buffer: 6.0, videoTrackCount: 1
        )
        #expect(!audioRunningNoFrame.isPlayingMedia)
    }

    @Test("the stall fingerprint tracks buffer, position and tracks")
    func signatureTracksMovingSignals() {
        let base = PlaybackSnapshot(position: 0, buffer: 1)
        #expect(base.progressSignature != PlaybackSnapshot(position: 0, buffer: 2).progressSignature)
        #expect(base.progressSignature != PlaybackSnapshot(position: 1, buffer: 1).progressSignature)
        #expect(
            base.progressSignature
                != PlaybackSnapshot(position: 0, buffer: 1, videoTrackCount: 1).progressSignature
        )
    }

    @Test("the fingerprint resolves sub-second movement")
    func signatureUsesMilliseconds() {
        // Seconds-granularity rounding would make a slowly-filling buffer look
        // stalled, which is exactly the false positive this logic exists to
        // avoid.
        let a = PlaybackSnapshot(buffer: 1.000)
        let b = PlaybackSnapshot(buffer: 1.250)
        #expect(a.progressSignature != b.progressSignature)
    }
}

@Suite("Connect loop")
@MainActor
struct ConnectLoopTests {

    @Test("a stream that starts playing settles on the first attempt")
    func succeedsFirstTry() async {
        let engine = FakeEngine(script: [
            PlaybackSnapshot(buffer: 0.5),
            PlaybackSnapshot(width: 1920, buffer: 1.0),
        ])
        let model = makeModel(engine: engine)

        model.connect()
        await waitUntil { model.state == .playing }

        #expect(model.state == .playing)
        #expect(engine.openCount == 1)
        // No retry means no teardown — a healthy connection is left alone.
        #expect(engine.stopCount == 0)
    }

    @Test("a hard engine error fails fast rather than waiting out the stall timeout")
    func failsFastOnEngineError() async {
        let engine = FakeEngine(script: [PlaybackSnapshot()])
        engine.lastError = "decoder gave up"
        let model = makeModel(engine: engine)

        let start = ContinuousClock.now
        model.connect()
        await waitUntil(timeout: .seconds(40)) {
            if case .failed = model.state { return true }
            return false
        }

        // Three attempts with 5s + 10s backoff, but *no* 12s stall wait each —
        // that would push this past 50s.
        #expect(ContinuousClock.now - start < .seconds(30))
        #expect(engine.openCount == PlayerModel.maxAttempts)
    }

    @Test("every retry releases the upstream connection first")
    func stopsBeforeEachRetry() async {
        let engine = FakeEngine(script: [PlaybackSnapshot()])
        engine.lastError = "no route to host"
        let model = makeModel(engine: engine)

        model.connect()
        await waitUntil(timeout: .seconds(40)) {
            if case .failed = model.state { return true }
            return false
        }

        // The proxy can still be holding the previous session when the retry
        // arrives; without the stop the provider refuses it.
        #expect(engine.calls == ["open", "stop", "open", "stop", "open"])
    }

    @Test("retries are capped")
    func retriesAreCapped() async {
        let engine = FakeEngine(script: [PlaybackSnapshot()])
        engine.lastError = "connection limit reached"
        let model = makeModel(engine: engine)

        model.connect()
        await waitUntil(timeout: .seconds(40)) {
            if case .failed = model.state { return true }
            return false
        }

        // Each attempt is a fresh upstream connection. Hammering the proxy is
        // the failure the retry exists to survive, not a fix for it.
        #expect(engine.openCount == 3)
    }

    @Test("a second connect supersedes the first without overlapping it")
    func secondConnectSupersedes() async {
        let engine = FakeEngine(script: [PlaybackSnapshot()])
        engine.lastError = "stalled"
        let model = makeModel(engine: engine)

        model.connect()
        try? await Task.sleep(for: .milliseconds(300))
        model.connect()
        try? await Task.sleep(for: .milliseconds(300))

        // Two loops each holding their own connection is the bug this guards.
        // The superseding call must wait for the first to unwind, so opens
        // cannot outpace the number of attempts started.
        #expect(engine.openCount <= 2)
    }

    @Test("teardown releases the connection even mid-connect")
    func teardownReleasesMidConnect() async {
        let engine = FakeEngine(script: [PlaybackSnapshot()])
        let model = makeModel(engine: engine)

        model.connect()
        try? await Task.sleep(for: .milliseconds(200))
        await model.teardown()

        // Teardown must not queue behind a connect that never completes —
        // that would hold the socket open while the user is already elsewhere.
        #expect(engine.stopCount >= 1)
    }

    @Test("a missing stream URL fails immediately")
    func missingURLFails() async {
        let engine = FakeEngine()
        let model = PlayerModel(
            channelName: "Test", streamURL: nil, programs: [], engine: engine
        )

        model.connect()
        await waitUntil { if case .failed = model.state { return true }; return false }

        #expect(engine.openCount == 0)
    }
}

/// Polls `condition` until it holds or the timeout expires.
///
/// The connect loop is time-driven, so tests observe it rather than stepping it.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

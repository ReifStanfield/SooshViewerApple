import Foundation
import Observation

/// Connect, stall-detect and retry logic for one channel.
///
/// **This is a faithful port, not a simplification.** The comments explaining
/// *why* each limit exists are carried over deliberately: an earlier Flutter
/// version polled video width with a hard 15s wall clock and re-opened on
/// timeout, which tore down healthy connections and burned the provider's
/// connection slots — visible server-side as connects that almost complete and
/// then drop.
///
/// One thing genuinely *is* simpler. Flutter needed two mechanisms to stop
/// overlapping connect loops: a generation counter (`_openGen`), because it
/// stops a superseded loop at its next await but cannot cancel an `open()`
/// already in flight, plus chaining onto the previous attempt's future so the
/// new one waits for the old to unwind. Swift's `Task` does both: cancellation
/// propagates into the awaits, and awaiting the old task's result before
/// starting is the chaining. See `connect()`.
@MainActor
@Observable
final class PlayerModel {
    enum ConnectionState: Equatable {
        case idle
        case connecting(attempt: Int, of: Int)
        case playing
        case failed(String)
    }

    private(set) var state: ConnectionState = .idle

    let engine: any PlaybackEngine
    let channelName: String
    let streamURL: URL?
    let programs: [Program]

    /// The concrete engine, when there is one.
    ///
    /// The model deals in the protocol so tests can inject a fake; the view
    /// needs the real `AVPlayer` to render. One downcast, in one place, that
    /// returns nil instead of crashing under test.
    var avEngine: AVPlayerEngine? { engine as? AVPlayerEngine }

    /// Bumped on a timer so the overlay's clock and progress bar advance
    /// without touching playback.
    private(set) var tick: Date = .now

    /// Whether the custom control layer is showing.
    ///
    /// Ordinary app state, not a gesture state: it survives the finger lifting
    /// and is changed by a timer as well as by taps.
    private(set) var controlsVisible: Bool = true

    private var hideTask: Task<Void, Never>?

    /// How long the controls linger after the last interaction. Matches the
    /// Flutter overlay's `_scheduleHide`.
    private static let autoHideDelay: Duration = .seconds(4)

    /// Shows the controls and restarts the auto-hide countdown.
    ///
    /// Call this from every control tap, so interacting with one button does not
    /// let the layer vanish mid-gesture.
    func pokeControls() {
        controlsVisible = true
        scheduleHide()
    }

    func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            controlsVisible = false
        } else {
            pokeControls()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autoHideDelay)
            guard let self, !Task.isCancelled else { return }
            // Never hide the controls over a paused picture — the user has no
            // other way back to the play button.
            guard self.engine.isPlaying else { return }
            self.controlsVisible = false
        }
    }

    private var connectTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    init(
        channelName: String,
        streamURL: URL?,
        programs: [Program],
        engine: any PlaybackEngine = AVPlayerEngine()
    ) {
        self.channelName = channelName
        self.streamURL = streamURL
        self.programs = programs
        self.engine = engine
    }

    // MARK: - Tunables, all load-bearing

    /// Deliberately few. Each attempt is a fresh upstream connection through the
    /// proxy, so hammering it exhausts the provider's connection slots — the
    /// exact failure the retry is meant to survive.
    static let maxAttempts = 3

    /// Give up only after this long with no measurable progress at all.
    static let stallTimeout: Duration = .seconds(12)

    /// Absolute ceiling, so a stream that trickles forever still fails.
    static let overallTimeout: Duration = .seconds(60)

    /// How often the connect loop samples the pipeline.
    static let pollInterval: Duration = .milliseconds(250)

    /// Backoff before attempt *n+1*: 5s then 10s. Long enough for the server to
    /// actually drop the old session; a tight loop just races itself.
    static func backoff(afterAttempt attempt: Int) -> Duration { .seconds(5 * attempt) }

    // MARK: - Connect

    /// Starts a connect attempt, superseding any that is already running.
    ///
    /// Two callers can collide: the initial `.task`, and the retry button, which
    /// is live during the backoff delay.
    func connect() {
        let previous = connectTask
        previous?.cancel()

        connectTask = Task { [weak self] in
            // Wait for the superseded attempt to actually unwind before opening
            // a second connection. Cancellation is a *request*; the old loop
            // still has to reach its next check and run its cleanup.
            _ = await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.runConnect()
        }
    }

    private func runConnect() async {
        guard let streamURL else {
            state = .failed("No stream URL for this channel.")
            return
        }

        for attempt in 1...Self.maxAttempts {
            if Task.isCancelled { return }
            state = .connecting(attempt: attempt, of: Self.maxAttempts)

            do {
                try await engine.open(url: streamURL, headers: [:])
                if await awaitPlayback() {
                    guard !Task.isCancelled else { return }
                    state = .playing
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                print("OPEN attempt \(attempt) failed: \(error)")
            }

            if Task.isCancelled { return }

            if attempt < Self.maxAttempts {
                // Release the upstream connection before asking for another one.
                // Without this the proxy can still be holding the previous
                // session open when the retry arrives, and the provider refuses
                // it.
                await engine.stop()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.backoff(afterAttempt: attempt))
            }
        }

        guard !Task.isCancelled else { return }
        state = .failed(
            "Could not connect. Your provider may be at its connection limit."
        )
    }

    /// Waits for playback to start, tolerating slow providers.
    ///
    /// Polling video width alone was too blunt: a live stream can be connected
    /// and buffering for a long time before the demuxer reports dimensions.
    /// Timing out on that restarted a healthy connection — and each restart
    /// costs another upstream connection slot.
    ///
    /// So this is a **stall** timeout, not a wall-clock one: as long as any
    /// signal is still moving (buffered duration, position, tracks appearing) it
    /// keeps waiting, up to `overallTimeout`.
    private func awaitPlayback() async -> Bool {
        let deadline = ContinuousClock.now + Self.overallTimeout
        var lastChangeAt = ContinuousClock.now
        var lastSignature: String?

        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }

            let snapshot = engine.snapshot

            // A decoded frame — or a running audio track, for audio-only streams
            // that never report a width — is unambiguous: we are playing.
            if snapshot.isPlayingMedia { return true }

            // A hard engine failure is not a stall. Fail now rather than
            // burning the full 12 seconds waiting for a pipeline that has
            // already given up.
            if engine.lastError != nil { return false }

            let signature = snapshot.progressSignature
            if signature != lastSignature {
                lastSignature = signature
                lastChangeAt = .now
            } else if ContinuousClock.now - lastChangeAt > Self.stallTimeout {
                return false
            }

            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                return false  // cancelled
            }
        }
        return false
    }

    // MARK: - Overlay

    /// Drives the clock and progress bar forward. 20s matches the Flutter timer;
    /// a programme block is an hour, so finer updates buy nothing.
    func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled else { return }
                self.tick = .now
            }
        }
    }

    /// The programme airing right now, or nil in a gap / with no EPG data.
    var currentProgram: Program? {
        _ = tick  // read so @Observable re-evaluates views on each tick
        return programs.first { $0.isAiring(at: .now) }
    }

    var progress: Double {
        _ = tick
        return currentProgram?.progress(at: .now) ?? 0
    }

    /// The programme starting after the current one, for the timeline's
    /// "up next" segment.
    var nextProgram: Program? {
        _ = tick
        guard let current = currentProgram else {
            return programs.first { $0.startTime > .now }
        }
        return programs.first { $0.startTime >= current.endTime }
    }

    /// Releases the connection and stops both loops.
    ///
    /// Called from the view's `.task` cancellation path. Teardown deliberately
    /// does not wait for an in-flight connect: cancelling first means a hung
    /// `open()` cannot hold the socket open while the user is already on another
    /// screen.
    func teardown() async {
        connectTask?.cancel()
        tickTask?.cancel()
        hideTask?.cancel()
        await engine.stop()
    }
}

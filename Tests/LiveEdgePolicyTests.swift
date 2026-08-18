import Foundation
import Testing

@testable import Soosh

/// Tests for the live-edge catch-up decision.
///
/// The bug these guard against: the rewrap pulls upstream in real time whether
/// or not anything is watching, so a player that stalls — the app occluded by
/// another full-screen app on Catalyst is the reliable way to cause it — falls
/// behind a window that keeps moving. Once the window's start passes the
/// player's position, every segment request is a 404 and nothing brings it back.
///
/// **The numbers here come from measurements, not from the spec.** With six
/// segments published, AVFoundation reported `currentTime` 14.81 against a
/// seekable range of `0.00…6.01` — healthy playback sits *ahead* of
/// `seekableEnd`, because a live client may not seek within three target
/// durations of the end. The first version of this policy compared against
/// `seekableEnd` as though it were the live edge and could never have fired.
///
/// An established window is ~16s of seekable span: ten segments of ~2.5s, less
/// the three target durations a live client stays back from the end. Fixtures
/// here use that, because a 6s span is a window that is still filling and the
/// policy now treats the two differently.
@Suite("Live edge policy")
struct LiveEdgePolicyTests {
    @Test("healthy playback ahead of the seekable end is left alone")
    func healthyPlaybackIsUntouched() {
        // The measured shape, shifted so the window has begun sliding.
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 124.81, seekableStart: 100, seekableEnd: 116
        ) == nil)
    }

    @Test("a fresh stream is left alone while its window is still filling")
    func fillingWindowIsUntouched() {
        // Nothing has been evicted yet, so a position close to the start is
        // normal rather than stranded.
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 2, seekableStart: 0, seekableEnd: 6
        ) == nil)
    }

    @Test("the handover window does not trip the margin")
    func handoverDoesNotJump() {
        // Measured at handover on a real channel. A live client starts three
        // target durations back, so it legitimately sits near the start of a
        // window that is still growing — this used to fire and jump to live in
        // the first second of every stream.
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 4.10, seekableStart: 2.05, seekableEnd: 13.54
        ) == nil)
    }

    @Test("eviction is corrected even while the window is short")
    func evictionCorrectedInShortWindow() {
        // Being *behind* the start is unrecoverable whatever the window size:
        // every segment request from there is a 404.
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 1, seekableStart: 2.05, seekableEnd: 13.54
        ) == 13.54)
    }

    @Test("drifting close to the window start jumps to live")
    func nearEvictionJumps() {
        // 3s of headroom, inside the 5s margin, on an established window: the
        // next eviction strands it.
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 103, seekableStart: 100, seekableEnd: 116
        ) == 116)
    }

    @Test("a position already evicted jumps to live")
    func evictedPositionJumps() {
        // The permanent-choppiness case: the window slid past this position, so
        // every segment request from here is a 404.
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 90, seekableStart: 100, seekableEnd: 116
        ) == 116)
    }

    @Test("comfortable headroom above the window start is left alone")
    func comfortableHeadroomIsUntouched() {
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 120, seekableStart: 100, seekableEnd: 116
        ) == nil)
    }

    @Test("an unestablished window is left alone")
    func degenerateWindowIsIgnored() {
        // Before the first playlist load the range is empty or nonsense. Acting
        // on it would seek on the strength of nothing.
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 0, seekableStart: 0, seekableEnd: 0
        ) == nil)
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 10, seekableStart: 20, seekableEnd: 5
        ) == nil)
    }

    @Test("the margin leaves room to jump but fits inside the window")
    func marginIsSanelyPlaced() {
        // Below a GOP it would fire on ordinary jitter; above the server's ~25s
        // window it would fire constantly.
        #expect(LiveEdgePolicy.evictionMargin > 2.5)
        #expect(LiveEdgePolicy.evictionMargin < 25)
    }
}

/// The catch-up *decision* is `LiveEdgePolicy`; the guards around actually
/// issuing the seek live in `AVPlayerEngine.catchUpToLiveEdge`, because they
/// depend on player state this type deliberately knows nothing about.
///
/// They are recorded here because each one is a bug that reached a user:
///
/// - **External playback.** On AirPlay the receiver owns the position and does
///   its own buffering. Seeking from the sending side fights it and knocks the
///   receiver's timebase out, which showed as a stream that rapidly played and
///   paused on Catalyst *after a couple of AirPlay sessions* — the giveaway that
///   it was route-related rather than stream-related.
/// - **Deliberate pause.** A paused live stream falls behind the window by
///   design; that is what pausing live TV is. The seek completion used to call
///   `play()` unconditionally, so a correction restarted playback the viewer had
///   stopped.
/// - **Seek storms.** A seek that does not take was re-issued every second, and
///   a seek per second is indistinguishable from a stutter. Corrections are now
///   rate-limited so the worst case is one visible jump per interval.
///
/// Asserting them properly needs a seekable `AVPlayer` fake, which
/// `PlaybackEngine` does not currently expose — `AVPlayerEngine` owns its
/// player outright. Left as a note rather than a silently missing case.
@Suite("Live edge guards")
struct LiveEdgeGuardTests {
    @Test("the policy still answers on the numbers alone")
    func policyIsIndependentOfPlayerState() {
        // The guards are the engine's job. The policy must stay a pure function
        // of the window, or it cannot be reasoned about in isolation.
        let target = LiveEdgePolicy.catchUpTarget(
            currentTime: 90, seekableStart: 100, seekableEnd: 106
        )
        #expect(target == 106)
    }
}

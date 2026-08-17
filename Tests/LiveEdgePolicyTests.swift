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
/// **The numbers here come from a measurement, not from the spec.** With six
/// segments published, AVFoundation reported `currentTime` 14.81 against a
/// seekable range of `0.00…6.01` — healthy playback sits *ahead* of
/// `seekableEnd`, because a live client may not seek within three target
/// durations of the end. The first version of this policy compared against
/// `seekableEnd` as though it were the live edge and could never have fired.
@Suite("Live edge policy")
struct LiveEdgePolicyTests {
    @Test("healthy playback ahead of the seekable end is left alone")
    func healthyPlaybackIsUntouched() {
        // The measured shape, shifted so the window has begun sliding.
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 114.81, seekableStart: 100, seekableEnd: 106.01
        ) == nil)
    }

    @Test("a fresh stream is left alone while its window is still filling")
    func fillingWindowIsUntouched() {
        // `seekableStart` of zero means nothing has been evicted yet, so a
        // position close to it is normal rather than stranded. Without this
        // guard the policy fires in the first seconds of every stream.
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 2, seekableStart: 0, seekableEnd: 6
        ) == nil)
    }

    @Test("drifting close to the window start jumps to live")
    func nearEvictionJumps() {
        // 3s of headroom, inside the 5s margin: the next eviction strands it.
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 103, seekableStart: 100, seekableEnd: 106.01
        ) == 106.01)
    }

    @Test("a position already evicted jumps to live")
    func evictedPositionJumps() {
        // The permanent-choppiness case: the window slid past this position, so
        // every segment request from here is a 404.
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 90, seekableStart: 100, seekableEnd: 106.01
        ) == 106.01)
    }

    @Test("comfortable headroom above the window start is left alone")
    func comfortableHeadroomIsUntouched() {
        #expect(LiveEdgePolicy.catchUpTarget(
            currentTime: 120, seekableStart: 100, seekableEnd: 106.01
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

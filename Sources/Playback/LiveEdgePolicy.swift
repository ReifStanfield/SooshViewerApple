import Foundation

/// When a live stream should give up on where it was and jump to now.
///
/// **This exists because live playback has no way back on its own.** The rewrap
/// pulls upstream in real time whether or not anything is watching, so the
/// playlist window keeps sliding forward while a stalled player stands still.
/// Let that go on longer than the window and the next segment the player wants
/// has already been evicted — it 404s, falls further behind, and never catches
/// up. The symptom is a stream that plays fine, freezes while the app is
/// occluded, and is choppy from then on.
///
/// The trigger for that on Mac Catalyst is moving to another full-screen app,
/// but nothing here is Catalyst-specific: a sleeping display, a network hiccup
/// or a long enough spinner produces the same fall-behind.
///
/// **Live television's contract is "show me now", not "show me what I missed".**
/// So the correction is to seek to the live edge rather than to buffer harder.
///
/// Pure arithmetic, deliberately: the decision is the part worth testing, and it
/// needs neither a player nor a network to check.
enum LiveEdgePolicy {
    /// How close to eviction playback may drift before it is pulled forward.
    ///
    /// A margin, not a distance-behind-live: see the note below on why the
    /// obvious formulation does not work. Two GOPs of headroom, so the jump
    /// happens while there is still material to jump *from*.
    static let evictionMargin: TimeInterval = 5

    /// Where playback should land, or nil to leave it alone.
    ///
    /// **`seekableEnd` is not the live edge, and assuming it was is a mistake
    /// this code made first.** HLS forbids a live client from seeking within
    /// three target durations of the end, so AVFoundation reports a seekable
    /// range that stops well short of it. Measured against this server with six
    /// segments published: `currentTime` 14.81 against a seekable range of
    /// `0.00…6.01`. Healthy playback sits *ahead* of `seekableEnd`, so a test
    /// like `seekableEnd - currentTime > threshold` never fires at all.
    ///
    /// What actually goes wrong is eviction from the *other* end. The window
    /// slides forward while a stalled player stands still, `seekableStart`
    /// climbs, and once it passes the player's position every segment request is
    /// a 404 with no way back. So the signal is the gap between the position and
    /// the *start* of the window, and the trigger is that gap closing.
    ///
    /// - Parameters:
    ///   - currentTime: the player's position.
    ///   - seekableStart: oldest material the server still holds.
    ///   - seekableEnd: furthest point a live client is allowed to seek to,
    ///     which is what "go live" means in practice.
    static func catchUpTarget(
        currentTime: TimeInterval,
        seekableStart: TimeInterval,
        seekableEnd: TimeInterval,
        margin: TimeInterval = evictionMargin
    ) -> TimeInterval? {
        // A window that has not been established yet, or is nonsense. Seeking on
        // the strength of it would be worse than waiting.
        guard seekableEnd > seekableStart else { return nil }

        // Behind the window entirely. No amount of waiting recovers this — every
        // segment request from here is a 404 — so it is worth correcting even
        // while the window is still filling.
        if currentTime < seekableStart { return seekableEnd }

        // **Proximity to the start only means danger once the window is
        // established.** While it is still filling, the span is short and the
        // playhead sits legitimately close to the start, because a live client
        // begins three target durations back. Measured at handover on a real
        // channel: position 4.10 against a seekable range of `2.05…13.54`, which
        // tripped the margin and produced a jump to live in the first second of
        // every stream. Nothing was being evicted; the window was growing.
        guard seekableEnd - seekableStart >= margin * 3 else { return nil }

        // Close enough to the start that the next eviction will strand it.
        guard currentTime - seekableStart < margin else { return nil }
        return seekableEnd
    }
}

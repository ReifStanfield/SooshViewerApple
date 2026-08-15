import Foundation

/// A point-in-time read of the playback pipeline.
struct PlaybackSnapshot: Equatable, Sendable {
    /// Decoded video width; non-nil and positive once a frame exists.
    var width: Int?

    /// True once an audio track is producing output, for audio-only streams
    /// that never report a width.
    var hasAudio: Bool = false

    var position: TimeInterval = 0
    var buffer: TimeInterval = 0
    var videoTrackCount: Int = 0

    /// A decoded frame, or a running audio track, means we are playing.
    var isPlayingMedia: Bool {
        (width ?? 0) > 0 || (hasAudio && position > 0)
    }

    /// Fingerprint of everything that moves while a stream connects.
    ///
    /// The connect logic compares this over time: while it changes, the pipeline
    /// is making progress and should be left alone.
    ///
    /// A buffering *flag* is deliberately not part of this. It only ever holds
    /// two values and flips between them while a stream rebuffers, so a player
    /// wedged in a buffering loop would look like it was making progress right
    /// up to the connect loop's overall ceiling. Buffered duration and position
    /// are the signals that actually advance.
    var progressSignature: String {
        let bufferMS = Int((buffer * 1000).rounded())
        let positionMS = Int((position * 1000).rounded())
        return "\(bufferMS)/\(positionMS)/\(videoTrackCount)"
    }
}

/// A video engine, behind a protocol.
@MainActor
protocol PlaybackEngine: AnyObject {
    /// Starts playing `url`. Returning does **not** mean a frame has arrived.
    func open(url: URL, headers: [String: String]) async throws

    /// Releases the upstream connection.
    func stop() async

    func playOrPause()

    /// Current pipeline state.
    var snapshot: PlaybackSnapshot { get }

    /// Latest engine error, or nil. Latches until the next `open`.
    var lastError: String? { get }

    var isPlaying: Bool { get }
}

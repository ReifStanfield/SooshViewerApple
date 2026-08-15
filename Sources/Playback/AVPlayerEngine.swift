import AVFoundation
// AVPictureInPictureController lives in AVKit, not AVFoundation — the split is
// "media pipeline" vs "media UI", and PiP counts as UI.
import AVKit
import Observation

/// Playback through AVPlayer.
///
/// HLS is AVPlayer's native format: adaptive bitrate, live-edge handling and
/// playlist reloads are the OS's problem, not ours. It also brings AirPlay,
/// Picture-in-Picture, Now Playing and background audio for free.
///
/// **This is much smaller than `VideoPlayerPlaybackController`, and the reason
/// is worth understanding.** That class tracks every controller it has ever
/// created in a `Set`, because `VideoPlayerController` is bound to its data
/// source for life — every `open()` had to build a new one, and one superseded
/// mid-`initialize()` still owned a live socket with nothing left to dispose it.
///
/// AVPlayer is not bound to its item. One player lives for the view's lifetime
/// and `replaceCurrentItem(with:)` swaps the source, so there is never a second
/// object holding a connection. The tracking set, the serialisation queue, and
/// the `_disposed` re-check all become unnecessary.
///
/// What does **not** go away is the pause-before-release rule.
@MainActor
@Observable
final class AVPlayerEngine: PlaybackEngine {
    /// Exposed so the view can hand it to AVPlayerViewController. Created once.
    let player = AVPlayer()

    private(set) var lastError: String?
    private(set) var isPlaying: Bool = false
    private var audioChannelCount: Int?

    /// KVO tokens. Held so they can be invalidated — an observation that
    /// outlives its item fires against a dead object.
    private var observations: [NSKeyValueObservation] = []

    /// The failure-notification token, wrapped so it can clean itself up.
    ///
    /// `deinit` is `nonisolated` — it can run on any thread — so it cannot touch
    /// `@MainActor` state directly. Handing ownership to a small nonisolated box
    /// means ARC unregisters the observer when this object goes away, whether or
    /// not `stop()` was ever called.
    private var failureObserver: NotificationToken?

    init() {
        // `automaticallyWaitsToMinimizeStalling` is deliberately left at its
        // default of `true`.
        //
        // It was set to `false` here on the theory that a live stream should
        // start at the live edge rather than buffer first. That is wrong for
        // HLS: with waiting disabled the player will not hold at rate 0 while
        // the first segments arrive — it simply drops the requested rate to 0
        // and never picks it back up. The symptom was a first frame on screen,
        // `timeControlStatus == .playing`, and `currentTime()` pinned at 0.00
        // forever.
        //
        // It went unnoticed for two rounds because `AVPlayerViewController`
        // resets this property on any player handed to it. Swapping to a bare
        // `AVPlayerLayer` for the custom controls removed that safety net and
        // exposed the original mistake.
    }

    /// True once the shared audio session has been configured for this engine.
    private var audioSessionReady = false

    /// Without this, audio stops when the ring/silent switch is set to silent,
    /// and playback dies when the app is backgrounded.
    ///
    /// **Called from `open()`, never from `init`.** `AVAudioSession` is a
    /// process-wide singleton and `setActive(true)` on it is not free — it can
    /// interrupt whatever is already playing. Doing this in `init` meant every
    /// throwaway engine SwiftUI constructed during a rebuild kicked the shared
    /// session. Configure the session when you are about to use it, not when you
    /// are merely allocated.
    private func configureAudioSession() {
        guard !audioSessionReady else { return }
        audioSessionReady = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Not fatal — video still plays, audio routing is just less correct.
            print("AVAudioSession setup failed: \(error)")
        }
    }

    func open(url: URL, headers: [String: String]) async throws {
        configureAudioSession()
        await stop()

        // `AVURLAssetHTTPHeaderFieldsKey` is how everyone passes auth headers to
        // AVFoundation, but it is not in the public headers. The supported
        // alternative is an AVAssetResourceLoaderDelegate, which means
        // reimplementing HLS playlist fetching by hand. Dispatcharr's
        // `/proxy/ts/stream/` allows anonymous access, so this path is only
        // exercised if an apiKey is ever supplied.
        let options: [String: Any] = headers.isEmpty
            ? [:]
            : ["AVURLAssetHTTPHeaderFieldsKey": headers]

        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        observe(item)
        player.replaceCurrentItem(with: item)
        player.play()

        // Track lists are loaded, not read: the modern AVFoundation accessors
        // are async because the asset may still be fetching its playlist. The
        // sync `mediaSelectionGroup(forMediaCharacteristic:)` is deprecated and
        // would block. Failures here are non-fatal — the stream plays, the
        // pickers are just empty.
        audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        subtitleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        await refreshAudioChannelCount(for: item)
    }

    // MARK: - Stream metadata

    /// What the pipeline can say about the stream it is decoding.
    ///
    /// Everything here is read from the *live* item, so it is only meaningful
    /// once playback has started — before that the fields are nil and the badges
    /// simply do not render. Nothing is guessed: a field the stream does not
    /// declare stays nil rather than being filled with a plausible default.
    struct StreamInfo: Equatable {
        var width: Int?
        var height: Int?
        var frameRate: Double?
        var audioChannels: Int?

        /// `4K` / `HD` / `SD`, by the usual broadcast thresholds.
        var resolutionLabel: String? {
            guard let height, height > 0 else { return nil }
            if height >= 2000 { return "4K" }
            if height >= 700 { return "HD" }
            if height >= 1000 { return "FHD"}
            return "SD"
        }

        var frameRateLabel: String? {
            guard let frameRate, frameRate > 0 else { return nil }
            // `currentVideoFrameRate` is *measured*, so it drifts — a 59.94 fps
            // stream reported 61 and the badge said "61 FPS", which looks like a
            // bug even though the number is honest. Snapping to the nearest
            // broadcast rate reports what the stream actually is; anything not
            // close to a standard rate is shown as measured rather than forced.
            let standard: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
            let nearest = standard.min { abs($0 - frameRate) < abs($1 - frameRate) }
            if let nearest, abs(nearest - frameRate) <= 1.5 {
                return "\(Int(nearest.rounded())) FPS"
            }
            return "\(Int(frameRate.rounded())) FPS"
        }

        var audioLabel: String? {
            guard let audioChannels, audioChannels > 0 else { return nil }
            switch audioChannels {
            case 1: return "MONO"
            case 2: return "STEREO"
            default: return "\(audioChannels).0"
            }
        }
    }

    var streamInfo: StreamInfo {
        guard let item = player.currentItem, item.status == .readyToPlay else {
            return StreamInfo()
        }
        var info = StreamInfo()
        info.audioChannels = audioChannelCount

        let size = item.presentationSize
        if size.width > 0 {
            info.width = Int(size.width.rounded())
            info.height = Int(size.height.rounded())
        }

        for track in item.tracks {
            guard let asset = track.assetTrack else { continue }
            switch asset.mediaType {
            case .video:
                // `currentVideoFrameRate` is on the *item* track and reflects
                // what is actually being decoded, unlike the asset track's
                // nominal rate — which is both deprecated and a declaration
                // rather than a measurement.
                if track.currentVideoFrameRate > 0 {
                    info.frameRate = Double(track.currentVideoFrameRate)
                }
            default:
                break
            }
        }
        return info
    }

    private func refreshAudioChannelCount(for item: AVPlayerItem) async {
        var channelCount: Int?
        for track in item.tracks {
            guard let asset = track.assetTrack, asset.mediaType == .audio else { continue }
            channelCount = try? await Self.channelCount(of: asset)
            if channelCount != nil { break }
        }

        guard player.currentItem === item else { return }
        audioChannelCount = channelCount
    }

    private static func channelCount(of track: AVAssetTrack) async throws -> Int? {
        let descriptions = try await track.load(.formatDescriptions)
        guard let audioDescription = descriptions.first else { return nil }
        guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)
        else { return nil }
        let channels = Int(basic.pointee.mChannelsPerFrame)
        return channels > 0 ? channels : nil
    }

    // MARK: - Track selection

    private(set) var audioGroup: AVMediaSelectionGroup?
    private(set) var subtitleGroup: AVMediaSelectionGroup?

    /// Currently selected option in `group`, or nil for "off".
    func selectedOption(in group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        player.currentItem?.currentMediaSelection.selectedMediaOption(in: group)
    }

    func select(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
        player.currentItem?.select(option, in: group)
        // `currentMediaSelection` is not KVO-observable in a way @Observable
        // picks up, so nudge the tracked property to re-render the menus.
        selectionRevision &+= 1
    }

    /// Bumped whenever a selection changes, purely so `@Observable` views that
    /// read it re-evaluate. Reading a non-observable AVFoundation property
    /// inside `body` would otherwise never update.
    private(set) var selectionRevision: UInt = 0

    /// Language code of the active audio track, uppercased — "UNK" when the
    /// stream declares none, which is common for these providers.
    var audioLanguageLabel: String {
        _ = selectionRevision
        guard let audioGroup,
            let option = selectedOption(in: audioGroup),
            let code = option.locale?.language.languageCode?.identifier
        else {
            return "UNK"
        }
        return code.uppercased()
    }

    private func observe(_ item: AVPlayerItem) {
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "Playback failed."
                Task { @MainActor [weak self] in self?.lastError = message }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let playing = player.timeControlStatus == .playing
                Task { @MainActor [weak self] in self?.isPlaying = playing }
            },
        ]

        // A stream that dies mid-playback never changes `status` — it is already
        // .readyToPlay. This is the only signal for it.
        failureObserver = NotificationToken(
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                let message = error?.localizedDescription ?? "Stream ended unexpectedly."
                Task { @MainActor [weak self] in self?.lastError = message }
            }
        )
    }

    /// Gives the upstream session back, as promptly as the platform allows.
    func stop() async {
        player.pause()
        player.replaceCurrentItem(with: nil)

        observations.forEach { $0.invalidate() }
        observations.removeAll()
        failureObserver = nil

        lastError = nil
        isPlaying = false
        audioChannelCount = nil
    }

    func playOrPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    // MARK: - Picture in Picture

    #if os(iOS)
        // Not observed: nothing in a view body reads it, and @Observable would
        // otherwise generate tracking for a type views never touch.
        @ObservationIgnored private var pipController: AVPictureInPictureController?

        var isPictureInPictureAvailable: Bool {
            AVPictureInPictureController.isPictureInPictureSupported()
                && pipController?.isPictureInPicturePossible == true
        }

        /// Attaches PiP to the layer the view just created.
        func attachPictureInPicture(to layer: AVPlayerLayer) {
            guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
            pipController = AVPictureInPictureController(playerLayer: layer)
        }

        func togglePictureInPicture() {
            guard let pipController else { return }
            if pipController.isPictureInPictureActive {
                pipController.stopPictureInPicture()
            } else {
                pipController.startPictureInPicture()
            }
        }
    #endif

    var snapshot: PlaybackSnapshot {
        guard let item = player.currentItem, item.status == .readyToPlay else {
            return PlaybackSnapshot()
        }

        let size = item.presentationSize
        let width = Int(size.width.rounded())
        let buffered = item.loadedTimeRanges
            .map { CMTimeGetSeconds($0.timeRangeValue.end) }
            .max() ?? 0

        let position = CMTimeGetSeconds(item.currentTime())

        // Whether the *stream* carries video at all, which is not the same
        // question as whether a frame has been decoded yet.
        let hasVideoTrack = item.tracks.contains { $0.assetTrack?.mediaType == .video }

        return PlaybackSnapshot(
            width: width > 0 ? width : nil,
            // Only genuinely audio-only streams get the shortcut.
            hasAudio: !hasVideoTrack,
            position: position.isFinite ? position : 0,
            buffer: buffered.isFinite ? buffered : 0,
            videoTrackCount: hasVideoTrack ? 1 : 0
        )
    }

}

/// Owns a NotificationCenter observer token and unregisters it on deallocation.
private final class NotificationToken {
    // `addObserver` hands back `any NSObjectProtocol`, which carries no
    // Sendable guarantee.
    nonisolated(unsafe) private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

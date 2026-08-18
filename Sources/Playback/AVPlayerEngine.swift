import AVFoundation
// AVPictureInPictureController lives in AVKit, not AVFoundation — the split is
// "media pipeline" vs "media UI", and PiP counts as UI.
import AVKit
import os
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
    ///
    /// **macOS has no `AVAudioSession` at all** — it is not deprecated there,
    /// the class is unavailable. Nothing is lost by skipping it: the session
    /// exists to negotiate with a ring/silent switch and with backgrounding
    /// rules, and a Mac has neither. Core Audio routes the output without being
    /// asked.
    private func configureAudioSession() {
        #if !os(macOS)
            guard !audioSessionReady else { return }
            audioSessionReady = true
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                // Not fatal — video still plays, audio routing is just less correct.
                print("AVAudioSession setup failed: \(error)")
            }
        #endif
    }

    /// The live rewrap, when this stream is a raw transport stream.
    ///
    /// Held so it can be torn down with the item — it owns the upstream socket,
    /// and leaking one leaves Dispatcharr counting the channel as in use.
    @ObservationIgnored private var rewrap: TSRewrapSession?

    /// Whether `url` is a raw MPEG-TS body rather than something AVFoundation
    /// can open directly.
    ///
    /// Matched on the path rather than a file extension: these URLs end in a
    /// channel UUID, not `.ts`.
    static func needsRewrap(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/proxy/ts/") || path.hasSuffix(".ts")
    }

    func open(url: URL, headers: [String: String]) async throws {
        configureAudioSession()
        await stop()

        // **Raw transport streams are wrapped in HLS before AVFoundation sees
        // them.** This is where the FFmpeg dependency used to be. AVFoundation
        // decodes MPEG-TS — it is HLS's original segment container, and these
        // channels are ordinary H.264/AAC — but it cannot consume an endless,
        // unindexed TS body. `TSRewrapSession` holds that socket open, cuts the
        // bytes at keyframes and serves them back as a live playlist on
        // loopback, so the same picture arrives through the HLS client Apple
        // already wrote. See Sources/Playback/TransportStream.
        var url = url
        if Self.needsRewrap(url) {
            let session = TSRewrapSession(upstreamURL: url, headers: headers)
            rewrap = session
            url = try await session.start()

        }

        // `AVURLAssetHTTPHeaderFieldsKey` is how everyone passes auth headers to
        // AVFoundation, but it is not in the public headers. The supported
        // alternative is an AVAssetResourceLoaderDelegate, which means
        // reimplementing HLS playlist fetching by hand. Dispatcharr's
        // `/proxy/ts/stream/` allows anonymous access, so this path is only
        // exercised if an apiKey is ever supplied.
        //
        // On the rewrapped path there is nothing to authenticate to: the
        // headers were spent on the upstream request inside `TSRewrapSession`,
        // and what AVFoundation is loading is our own loopback server.
        var options: [String: Any] = (headers.isEmpty || rewrap != nil)
            ? [:]
            : ["AVURLAssetHTTPHeaderFieldsKey": headers]

        // **These streams are endless.** The rewrap gives them an index but not
        // an ending — the playlist carries no `EXT-X-ENDLIST`, because it is
        // live. Asking AVFoundation for precise timing still means reading ahead
        // for a duration that is never coming.
        options[AVURLAssetPreferPreciseDurationAndTimingKey] = false

        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)

        // **`preferredForwardBufferDuration` is left at the default of 0.**
        //
        // It was 2, to start on a small buffer rather than AVPlayer's automatic
        // one, on the reasoning that live television would rather be two seconds
        // behind than wait. On a rewrapped live playlist that value is smaller
        // than a single segment, and the item then never reaches
        // `.readyToPlay` at all: status stays `.unknown`, `tracks` stays empty,
        // and **nothing is written to `errorLog()`** — the failure is completely
        // silent, which is why it survived so long.
        //
        // 0 means "choose automatically", which is the only setting that works
        // here. Do not put a number back without checking that a channel still
        // starts in the *app* — a bare `AVPlayer` in a command-line harness does
        // not set this property and so never reproduced the bug.

        observe(item)
        player.replaceCurrentItem(with: item)
        player.play()

        // **Metadata is loaded alongside playback, never ahead of it.**
        //
        // These three awaits used to sit here, before `open()` returned — and
        // `PlayerModel` does not start watching for playback until it does. On a
        // stream with no playlist to parse they can take seconds or hang
        // outright, which delayed the *detection* of a stream that was already
        // playing, started the stall and overall clocks late, and showed
        // "connecting" over a live picture.
        //
        // Nothing here affects playback: it fills the audio and subtitle
        // pickers. It belongs off the connect path entirely.
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                // The user may already be on another channel.
                guard let self, self.player.currentItem === item else { return }
                self.audioGroup = audio
                self.subtitleGroup = subtitles
            }
            await self?.refreshAudioChannelCount(for: item)
        }
    }

    /// Loads the track lists without blocking the connect path.
    @ObservationIgnored private var metadataTask: Task<Void, Never>?

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

        // **Live-edge recovery**, only on the rewrapped path.
        //
        // A normal HLS asset or a file has an ending and can be left where the
        // user put it. A rewrapped live channel cannot: the upstream keeps
        // running while the app is occluded — moving to another full-screen app
        // on Catalyst is the reliable way to see it — so the playlist window
        // slides on while playback stands still, and past ~25s the segment the
        // player wants has been evicted. See `LiveEdgePolicy`.
        if rewrap != nil {
            startLiveEdgeWatch()

            // A stall is the fast signal for the same condition. The periodic
            // check would catch it a second later anyway, but a stall is exactly
            // when a second of black is most obvious.
            stallObserver = NotificationToken(
                NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.playbackStalledNotification,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.catchUpToLiveEdge() }
                }
            )
        }

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

    // MARK: - Live-edge recovery

    /// Periodic observer token. Held because it must be removed by hand —
    /// unlike KVO, a time observer outlives its player until it is.
    @ObservationIgnored private var liveEdgeObserver: Any?

    @ObservationIgnored private var stallObserver: NotificationToken?

    /// Dumps everything AVFoundation will tell us about a stream that is not
    /// playing yet.
    ///
    /// **This is here because reasoning from the outside kept being wrong.**
    /// `errorLog()` in particular carries faults that never surface as an item
    /// error and never reach `lastError` — a rejected playlist tag, a stale
    /// reload, a segment that 404'd — and it was reading those that identified
    /// the last two playback bugs. Cheap enough to leave on: it only runs on the
    /// live path, only while no frame has arrived, and only every few seconds.
    func logDiagnostics(reason: String) {
        guard let item = player.currentItem else {
            Self.log.notice("[\(reason)] no current item")
            return
        }
        let size = item.presentationSize
        let loaded = item.loadedTimeRanges.map(\.timeRangeValue).map {
            String(format: "%.1f…%.1f", CMTimeGetSeconds($0.start), CMTimeGetSeconds($0.end))
        }
        let seekable = item.seekableTimeRanges.map(\.timeRangeValue).map {
            String(format: "%.1f…%.1f", CMTimeGetSeconds($0.start), CMTimeGetSeconds($0.end))
        }
        // **`privacy: .public` on every value.** os_log redacts interpolated
        // values by default, and on Catalyst this whole line came back as
        // `<private>` — a diagnostic that tells you nothing is worse than none,
        // because it looks like you already checked.
        let summary = """
        [\(reason)] status=\(item.status.rawValue) rate=\(self.player.rate) \
        timeControl=\(self.player.timeControlStatus.rawValue) \
        pos=\(String(format: "%.2f", CMTimeGetSeconds(item.currentTime()))) \
        size=\(Int(size.width))x\(Int(size.height)) tracks=\(item.tracks.count) \
        loaded=\(loaded) seekable=\(seekable) \
        likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp) bufferEmpty=\(item.isPlaybackBufferEmpty)
        """
        Self.log.notice("\(summary, privacy: .public)")
        if let events = item.errorLog()?.events, !events.isEmpty {
            for event in events.suffix(3) {
                Self.log.error("[\(reason, privacy: .public)] errorLog \(event.errorStatusCode, privacy: .public): \(event.errorComment ?? "-", privacy: .public)")
            }
        }
        if let access = item.accessLog()?.events.last {
            let accessSummary = """
            [\(reason)] accessLog stalls=\(access.numberOfStalls) \
            dropped=\(access.numberOfDroppedVideoFrames) \
            segmentsDownloaded=\(access.numberOfMediaRequests) \
            indicatedBitrate=\(Int(access.indicatedBitrate))
            """
            Self.log.notice("\(accessSummary, privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "com.soosh.viewer", category: "AVPlayerEngine")

    /// Ticks since the watch started, so diagnostics can be throttled.
    @ObservationIgnored private var watchTicks = 0

    private func startLiveEdgeWatch() {
        stopLiveEdgeWatch()
        watchTicks = 0
        lastCatchUpAt = nil
        // Once a second. The threshold is 8s, so a finer interval buys nothing
        // and a coarser one lets the gap grow while we are not looking.
        liveEdgeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watchTicks += 1
                // Every 2s, and only until a frame has actually arrived.
                if self.watchTicks % 2 == 0, (self.snapshot.width ?? 0) == 0 {
                    self.logDiagnostics(reason: "connecting")
                }
                self.catchUpToLiveEdge()
            }
        }
    }

    private func stopLiveEdgeWatch() {
        if let liveEdgeObserver {
            player.removeTimeObserver(liveEdgeObserver)
            self.liveEdgeObserver = nil
        }
        stallObserver = nil
    }

    /// When the last catch-up seek was issued, so they cannot stack up.
    @ObservationIgnored private var lastCatchUpAt: ContinuousClock.Instant?

    /// Jumps to the live edge when playback has fallen too far behind it.
    private func catchUpToLiveEdge() {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }

        // **Not while AirPlay is driving playback.** On an external route the
        // receiver owns the position and does its own buffering; seeking from
        // this side fights it, and each correction knocks the receiver's timebase
        // out again, which is what produced a stream that rapidly played and
        // paused after a couple of AirPlay sessions on Catalyst.
        guard !player.isExternalPlaybackActive else { return }

        // **Not while deliberately paused.** A paused live stream falls behind
        // the window by design — that is what pausing live TV *is*. Correcting
        // it here would seek and then call `play()` below, restarting playback
        // the viewer had stopped. The correction belongs on the next tick after
        // they resume, which is where it now happens.
        guard player.timeControlStatus != .paused else { return }

        // **One correction at a time.** A seek that does not take — because the
        // route changed under us, or the window moved again while it was in
        // flight — would otherwise be re-issued every second, and a seek per
        // second on a live stream is indistinguishable from a stutter. Bounding
        // it means the worst case degrades to one visible jump per interval
        // rather than a storm.
        let attemptedAt = ContinuousClock.now
        if let lastCatchUpAt, attemptedAt - lastCatchUpAt < .seconds(5) { return }
        // The seekable range *is* the server's sliding window, republished by
        // AVFoundation — which is why this needs no knowledge of segment count
        // or target duration.
        guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return }

        let start = CMTimeGetSeconds(range.start)
        let end = CMTimeGetSeconds(range.end)
        let now = CMTimeGetSeconds(item.currentTime())
        guard now.isFinite, start.isFinite, end.isFinite else { return }

        guard let target = LiveEdgePolicy.catchUpTarget(
            currentTime: now,
            seekableStart: start,
            seekableEnd: end
        ) else { return }

        // **Tolerance is asymmetric on purpose.** `.zero` after and infinity
        // before lets AVFoundation land on the nearest earlier sync sample
        // rather than decoding forward to hit an exact time it does not need to.
        // A jump to live is a visible discontinuity for the viewer, so it is
        // worth a line every time — a *repeated* jump is the signature of the
        // policy fighting the stream rather than correcting it.
        Self.log.notice("""
        catch-up seek: pos=\(String(format: "%.2f", now), privacy: .public) \
        seekable=\(String(format: "%.2f", start), privacy: .public)…\(String(format: "%.2f", end), privacy: .public) \
        target=\(String(format: "%.2f", target), privacy: .public)
        """)

        lastCatchUpAt = attemptedAt
        let wasPlaying = player.timeControlStatus == .playing

        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .positiveInfinity,
            toleranceAfter: .zero
        ) { [weak self] finished in
            // Only resume what was already running. Calling `play()`
            // unconditionally turns a correction into a command.
            guard finished, wasPlaying else { return }
            MainActor.assumeIsolated { self?.player.play() }
        }
    }

    /// Gives the upstream session back, as promptly as the platform allows.
    func stop() async {
        // Cancelled first: a metadata load still in flight holds the asset, and
        // the asset holds the socket this is trying to give back.
        metadataTask?.cancel()
        metadataTask = nil

        // Before the item goes: a periodic observer left on a player whose item
        // has been replaced keeps firing against the new one.
        stopLiveEdgeWatch()

        player.pause()
        player.replaceCurrentItem(with: nil)

        // **After the pause, and after the item is gone.** The pause-before-
        // release rule now has a second half: the socket Dispatcharr counts is
        // the rewrap's, not AVPlayer's, so tearing the session down while the
        // player is still reading would leave the player fetching segments from
        // a server that has stopped being fed. Player first, then the session.
        if let rewrap {
            self.rewrap = nil
            await rewrap.stop()
        }

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

    // Excluded on tvOS rather than limited to iOS: `AVPictureInPictureController`
    // exists on macOS and behaves the same way, so the Mac gets PiP for free.
    // tvOS is the platform without it — the TV *is* the screen, so there is no
    // second window to float over.
    #if !os(tvOS)
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

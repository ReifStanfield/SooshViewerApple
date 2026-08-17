import AVKit
import SwiftUI

/// Full-screen playback for one channel.
///
/// The Flutter version hand-builds an overlay: back button, title, LIVE badge,
/// centre play/pause, a progress bar, and a `_rotate()` that drives
/// `SystemChrome.setPreferredOrientations`. Nearly all of that is
/// `AVPlayerViewController`'s job here — it supplies transport controls,
/// full-screen, AirPlay, Picture-in-Picture, and on tvOS the Siri Remote
/// gestures and the info panel, none of which had to be written.
///
/// What stays custom is the part AVKit cannot know: the connecting/retry state,
/// and the EPG programme line.
struct PlayerView: View {
    @State private var model: PlayerModel?

    private let channel: Channel
    private let streamURL: URL?
    private let programs: [Program]

    /// Artwork for the overlay's channel plate on tvOS.
    private let logoURL: URL?
    private let palette: LogoPalette?

    init(
        channel: Channel,
        streamURL: URL?,
        programs: [Program],
        logoURL: URL? = nil,
        palette: LogoPalette? = nil
    ) {
        self.logoURL = logoURL
        self.palette = palette
        self.channel = channel
        self.streamURL = streamURL
        self.programs = programs
    }

    var body: some View {
        Group {
            if let model, let engine = model.avEngine {
                loaded(model: model, engine: engine)
            } else {
                // One frame at most, while `.task` builds the model.
                Color.black.ignoresSafeArea()
            }
        }
        .task {
            guard model == nil else { return }
            let created = PlayerModel(
                channelName: channel.displayName,
                streamURL: streamURL,
                programs: programs
            )
            model = created
            created.startTicking()
            created.connect()
            created.pokeControls()
        }
        .onDisappear {
            let leaving = model
            Task { await leaving?.teardown() }
        }
    }

    @ViewBuilder
    private func loaded(model: PlayerModel, engine: AVPlayerEngine) -> some View {
        #if os(tvOS)
            // Edge to edge, with no navigation chrome. Presented as a
            // `fullScreenCover` (see `HomeView`), so it escapes the sidebar's
            // leading inset entirely — pushing it into the navigation stack left
            // the picture 120pt short of the left edge and sliding sideways
            // whenever the rail expanded.
            //
            // A bare `AVPlayerLayer`, not `AVPlayerViewController`: the overlay
            // below *is* the controls now, and a controller with its own
            // controls disabled still owns gestures and insets the layout.
            VideoLayerView(player: engine.player)
                .ignoresSafeArea()
                .overlay { TVPlayerControlsView(
                    model: model,
                    engine: engine,
                    channel: channel,
                    logoURL: logoURL,
                    palette: palette
                ) }
                .overlay { connectionOverlay(model) }
                // Menu exits, and any other remote input wakes the controls —
                // without the latter there is no way to bring them back once
                // they auto-hide.
                .onExitCommand { dismiss() }
                .onMoveCommand { _ in model.pokeControls() }
                .onPlayPauseCommand {
                    engine.playOrPause()
                    model.pokeControls()
                }
        #elseif os(iOS)
            iOSPlayer(model: model, engine: engine)
        #else
            // **macOS shares the live path's thin chrome rather than
            // `PlayerControlsView`.** That file is `#if os(iOS)` end to end, and
            // not incidentally: its transport rail is built for a thumb, and
            // `toggleFullScreen` drives `UIWindowScene.requestGeometryUpdate`,
            // which has no AppKit counterpart — a Mac window is resized by the
            // user, not by the app asking. Porting it is a real piece of design
            // work, not a `#if`, so the Mac gets the honest subset for now:
            // picture, connection state, a way out, play/pause.
            macPlayer(model: model, engine: engine)
        #endif
    }

    #if os(macOS)

        /// The player layout on macOS — which now means both the Catalyst
        /// variant and the native Mac target.
        private func macPlayer(model: PlayerModel, engine: AVPlayerEngine) -> some View {
            VideoLayerView(player: engine.player) { layer in
                engine.attachPictureInPicture(to: layer)
            }
            .ignoresSafeArea()
            .overlay { connectionOverlay(model) }
            .overlay(alignment: .topLeading) {
                if model.controlsVisible { macBackButton() }
            }
            .overlay {
                if model.controlsVisible, model.state == .playing {
                    macPlayPauseButton(isPlaying: engine.isPlaying) {
                        engine.playOrPause()
                        model.pokeControls()
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.toggleControls() }
        }

        @ViewBuilder
        private func macBackButton() -> some View {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .padding(20)
            .accessibilityLabel("Back")
        }

        @ViewBuilder
        private func macPlayPauseButton(isPlaying: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
        }

    #endif

    // Shared by both engine paths: the FFmpeg player has no controls
    // view of its own, so it reuses this connection state directly.

    @Environment(\.dismiss) private var dismiss

    /// Connecting spinner and the retry path. Separate from the control
    /// overlay so it stays up when the controls auto-hide.
    @ViewBuilder
    private func connectionOverlay(_ model: PlayerModel) -> some View {
        switch model.state {
        case .idle, .connecting:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                if case .connecting(let attempt, let total) = model.state {
                    Text("Connecting (\(attempt)/\(total))")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.35))

        case .failed(let message):
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 64))
                Text("Can't play this channel").font(.title)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { model.connect() }
            }
            .foregroundStyle(.white)
            .padding(60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.85))

        case .playing:
            EmptyView()
        }
    }

    #if os(iOS)
        private func iOSPlayer(model: PlayerModel, engine: AVPlayerEngine) -> some View {
            ZStack {
                Color.black.ignoresSafeArea()

                VideoLayerView(player: engine.player) { layer in
                    engine.attachPictureInPicture(to: layer)
                }
                .ignoresSafeArea()
                // A plain layer has no gestures of its own, so the show/hide tap
                // is ours to install. `contentShape` matters: without it the tap
                // only registers on drawn pixels, and the letterbox bars stay
                // dead.
                .contentShape(Rectangle())
                .onTapGesture { model.toggleControls() }

                PlayerControlsView(model: model, engine: engine) { dismiss() }

                failureOverlay(model)
            }
            // We draw our own back button and title, so the system chrome would
            // just be a second one. Safe to hide here precisely *because* the
            // surface is a plain layer now — the earlier bug where wrapping
            // AVPlayerViewController killed its controls does not apply.
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
        }

        /// Full-bleed failure state. Separate from the control layer so it stays
        /// visible and tappable when the controls have auto-hidden.
        @ViewBuilder
        private func failureOverlay(_ model: PlayerModel) -> some View {
            if case .failed(let message) = model.state {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Can't play this channel").font(.headline)
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Try again") { model.connect() }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.85))
            }
        }
    #endif

    // MARK: - tvOS chrome
    //
    // Only the tvOS branch renders these; iOS uses PlayerControlsView.

    #if os(tvOS)
        /// Feeds the native player its title, so the tvOS info panel is
        /// populated. This is the tvOS equivalent of the custom top bar.
        private func metadata(for model: PlayerModel) -> [AVMetadataItem] {
            let program = model.currentProgram
            return [
                metadataItem(.commonIdentifierTitle, value: program?.displayTitle ?? model.channelName),
                metadataItem(.commonIdentifierDescription, value: model.channelName),
            ].compactMap(\.self)
        }

        private func metadataItem(_ identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem? {
            guard !value.isEmpty else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item.copy() as? AVMetadataItem
        }

        @ViewBuilder
        private func statusOverlay(_ model: PlayerModel) -> some View {
            switch model.state {
            case .idle:
                EmptyView()

            case .connecting(let attempt, let total):
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting (\(attempt)/\(total))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

            case .playing:
                if let program = model.currentProgram {
                    HStack(spacing: 8) {
                        Text(program.displayTitle)
                        if program.isLive {
                            Text("LIVE")
                                .font(.caption.weight(.heavy))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Color(red: 0.886, green: 0.294, blue: 0.290),
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                        }
                    }
                    .foregroundStyle(.white)
                    .padding()
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }

            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't play this channel", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { model.connect() }
                }
            }
        }
    #endif
}

#if os(tvOS)

    /// Bridges `AVPlayerViewController` into SwiftUI, for tvOS only.
    ///
    /// iOS drives a bare `AVPlayerLayer` (see `VideoLayerView`) because it draws
    /// its own controls. tvOS keeps the system player, so it keeps the
    /// controller — which brings the focus engine, Siri Remote gestures and the
    /// info panel with it.
    struct VideoSurface: UIViewControllerRepresentable {
        let player: AVPlayer
        let metadata: [AVMetadataItem]

        func makeUIViewController(context: Context) -> AVPlayerViewController {
            let controller = AVPlayerViewController()
            controller.player = player
            return controller
        }

        func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
            if controller.player !== player {
                controller.player = player
            }
            // Metadata lives on the *item*, which is replaced on every
            // reconnect, so it is reapplied here rather than set once.
            controller.player?.currentItem?.externalMetadata = metadata
        }
    }

#endif

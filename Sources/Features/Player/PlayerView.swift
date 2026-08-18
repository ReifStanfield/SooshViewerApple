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

    /// Whether this view's player now belongs to the multiview grid.
    @State private var handedOff = false

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
            // **Not torn down when it was handed to the grid.** The tile is
            // playing this very model now; tearing it down here would stop the
            // stream the pop-out was supposed to keep running.
            guard !handedOff else { return }
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
        #else
            // Mac Catalyst compiles as iOS and takes this path too — the native
            // Mac target that used to need its own thinner chrome is gone.
            iOSPlayer(model: model, engine: engine)
        #endif
    }

    // Shared by both engine paths: the FFmpeg player has no controls
    // view of its own, so it reuses this connection state directly.

    @Environment(\.dismiss) private var dismiss

    /// The multiview session, for the "add to grid" control.
    @Environment(MultiviewModel.self) private var multiview

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
                    engine.adoptVideoLayer(layer)
                }
                .ignoresSafeArea()
                // A plain layer has no gestures of its own, so the show/hide tap
                // is ours to install. `contentShape` matters: without it the tap
                // only registers on drawn pixels, and the letterbox bars stay
                // dead.
                .contentShape(Rectangle())
                .onTapGesture { model.toggleControls() }

                PlayerControlsView(
                    model: model,
                    engine: engine,
                    logoURL: logoURL,
                    onBack: { dismiss() },
                    // **The full-screen player is torn down as it tiles.** The
                    // tile builds its own `PlayerModel`, so leaving this one
                    // running would mean two connections to the same channel —
                    // and the provider counts both. `onDisappear` already calls
                    // `teardown()`, so dismissing is the teardown.
                    onMultiview: {
                        // **Hands this exact player to the grid — no second
                        // connection, no second join.** Ownership moves with it,
                        // which is why `handedOff` exists below.
                        multiview.adopt(channel: channel, logoURL: logoURL, model: model)
                        handedOff = true
                        dismiss()
                    }
                )

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

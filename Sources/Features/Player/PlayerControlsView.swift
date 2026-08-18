import AVFoundation
import SwiftUI

#if os(iOS)

    /// The custom transport layer drawn over the video.
    ///
    /// Replaces `AVPlayerViewController`'s controls entirely. The layout is
    /// three anchored clusters plus a centre button and a timeline strip, rather
    /// than one big `VStack` — that way each cluster sizes to its own content
    /// and nothing reflows when, say, the audio-language label changes width.
    struct PlayerControlsView: View {
        @Bindable var model: PlayerModel
        let engine: AVPlayerEngine
        var logoURL: URL? = nil
        let onBack: () -> Void

        /// Hands this channel to the multiview grid and leaves the player.
        var onMultiview: () -> Void = {}

        #if targetEnvironment(macCatalyst)
            /// Width of the timeline row, and of the LIVE badge that rides on it.
            ///
            /// Both are measured rather than assumed because the badge has to be
            /// *centred on the playhead* and then kept inside the row — which
            /// needs its own width, not an estimate of it. `onGeometryChange`
            /// rather than a `GeometryReader` wrapper: a reader expands to fill
            /// its parent and would fight the surrounding `VStack`.
            @State private var timelineWidth: CGFloat = 0
            @State private var liveBadgeWidth: CGFloat = 0
        #endif

        var body: some View {
            // **One** container for the whole layer, not one per pill.
            //
            // `GlassEffectContainer` is what lets separate glass shapes sample a
            // shared backdrop and blend into each other when they come close —
            // wrapping each pill in its own container defeats that entirely and
            // just costs an extra render pass each. `spacing` is the distance at
            // which neighbours start to merge.
            GlassEffectContainer(spacing: 20) {
                ZStack {
                    // Still worth keeping under the glass: it darkens the video
                    // enough for white glyphs to hold contrast over a bright
                    // scene, which glass alone does not guarantee.
                    //
                    // The scrim is the one part that *should* reach the screen
                    // edges, so it opts out of the safe area on its own rather
                    // than the whole control layer doing so.
                    LinearGradient(
                        colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    // **The Mac layout is a fork, not a tuned variant.** A
                    // phone in portrait cannot carry a two-column bottom row
                    // with a programme synopsis in it, and a Mac window has no
                    // thumb-reach constraint to design around. `#if
                    // targetEnvironment(macCatalyst)` rather than a size class:
                    // this is about which platform's conventions apply, and an
                    // iPad at the same width still wants the touch layout.
                    #if targetEnvironment(macCatalyst)
                        catalystTopCluster
                        // Only the connecting spinner stays in the centre. On
                        // this layout play/pause lives next to the other
                        // transport controls at the bottom right, so leaving a
                        // second one mid-screen would be two of the same button.
                        catalystCentreButton
                        catalystBottomCluster
                    #else
                        topCluster
                        centreButton
                        bottomCluster
                    #endif
                }
            }
            .opacity(model.controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: model.controlsVisible)
            // Hidden controls must not keep swallowing taps — without this the
            // invisible layer still eats the tap meant to bring it back.
            .allowsHitTesting(model.controlsVisible)
        }

        // MARK: - Top

        private var topCluster: some View {
            VStack(alignment: .trailing, spacing: 12) {
                HStack(alignment: .top) {
                    CircleButton(systemImage: "arrow.left", action: onBack)
                    Spacer()
                    actionPill
                }
                HStack {
                    Spacer()
                    trackPill
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }

        /// Share and favourite are deliberately inert for now — they belong to
        /// app features that do not exist yet, and a button that silently does
        /// nothing is worse than one that says so.
        ///
        /// `RoutePickerButton` sits inline as a normal 44pt member of the row.
        /// An earlier version overlaid it on the heart with a hard-coded
        /// `.offset(x: 52)`, which pushed it clean off the screen edge —
        /// absolute offsets inside a layout that sizes to its content are always
        /// a guess, and this one was wrong.
        private var actionPill: some View {
            ControlPill {
                PillButton(systemImage: "square.and.arrow.up") {
                    model.pokeControls()  // TODO: share sheet
                }
                airPlayControl
                PillButton(systemImage: "heart") {
                    model.pokeControls()  // TODO: favourites
                }
            }
        }

        /// The AirPlay button: our glyph, Apple's tap target.
        ///
        /// `AVRoutePickerView` is the only way to raise the route picker, and it
        /// reports a much larger intrinsic size than we want in a row of 44pt
        /// buttons. `.overlay` sidesteps the negotiation entirely — an overlay is
        /// sized *by* its host and contributes nothing to layout — and tinting
        /// it clear leaves it as an invisible tap target over our own glyph.
        private var airPlayControl: some View {
            Image(systemName: "airplayvideo")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .overlay {
                    RoutePickerButton(tint: .clear)
                        .clipped()
                }
                .accessibilityLabel("AirPlay")
        }

        private var trackPill: some View {
            ControlPill {
                audioMenu {
                    HStack(spacing: 4) {
                        Text(engine.streamInfo.resolutionLabel ?? "UNK")
                            .font(.title3.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 44)
                }
                PillButton(systemImage: "ellipsis") {
                    model.pokeControls()  // TODO: overflow menu
                }
            }
        }

        /// The audio-track picker, parameterised by its label.
        ///
        /// Two controls open it — the "UNK ⌄" pill, which doubles as a readout
        /// of the current selection, and the waveform glyph at the bottom. Taking
        /// the label as a `@ViewBuilder` shares one menu body between them
        /// instead of the earlier trick of stacking a 0.001-opacity `Menu` on
        /// top of a `Button`, which worked but was invisible to VoiceOver.
        private func audioMenu<Label: View>(
            @ViewBuilder label: () -> Label
        ) -> some View {
            Menu {
                if let group = engine.audioGroup, !group.options.isEmpty {
                    ForEach(group.options, id: \.self) { option in
                        Button {
                            engine.select(option, in: group)
                            model.pokeControls()
                        } label: {
                            if engine.selectedOption(in: group) == option {
                                Label2(option.displayName, checked: true)
                            } else {
                                Label2(option.displayName, checked: false)
                            }
                        }
                    }
                } else {
                    Text("No alternate audio")
                }
            } label: {
                label()
            }
            .accessibilityLabel("Audio track")
        }

        // MARK: - Centre

        /// Spinner while connecting or rebuffering, play/pause once running.
        ///
        /// Both states live in one slot so the layout does not jump as playback
        /// settles — the thing the user is reaching for stays put.
        @ViewBuilder
        private var centreButton: some View {
            switch model.state {
            case .idle, .connecting:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(.white)

            case .playing:
                // Waiting for data is not the same as paused — see
                // `catalystPlayPause`. Rebuffering mid-stream shows the spinner
                // rather than inviting a tap that would stop it.
                if engine.isBuffering {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .tint(.white)
                        .frame(width: 72, height: 72)
                        .accessibilityLabel("Loading")
                } else {
                    Button {
                        engine.playOrPause()
                        model.pokeControls()
                    } label: {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .contentShape(Circle())
                    }
                    // Cross-fades the glyph instead of popping it.
                    .contentTransition(.symbolEffect(.replace))
                    .glassEffect(.regular.interactive(), in: Circle())
                }

            case .failed:
                EmptyView()  // the failure overlay in PlayerView owns this state
            }
        }

        // MARK: - Bottom

        private var bottomCluster: some View {
            VStack(spacing: 14) {
                Spacer()
                HStack(alignment: .center) {
                    ControlPill {
                        subtitleMenu
                        audioMenu {
                            Image(systemName: "waveform")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }
                    }
                    Spacer()
                    ControlPill {
                        PillButton(systemImage: "pip.enter") {
                            engine.togglePictureInPicture()
                            model.pokeControls()
                        }
                        PillButton(systemImage: "plus.rectangle.on.rectangle") {
                            onMultiview()
                        }
                        PillButton(systemImage: "arrow.up.left.and.arrow.down.right") {
                            toggleFullScreen()
                            model.pokeControls()
                        }
                    }
                }
                timeline
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }

        private var subtitleMenu: some View {
            Menu {
                if let group = engine.subtitleGroup {
                    Button("Off") {
                        engine.select(nil, in: group)
                        model.pokeControls()
                    }
                    ForEach(group.options, id: \.self) { option in
                        Button(option.displayName) {
                            engine.select(option, in: group)
                            model.pokeControls()
                        }
                    }
                } else {
                    Text("No subtitles")
                }
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
        }


        // MARK: - Mac Catalyst layout

        #if targetEnvironment(macCatalyst)

            /// Back on the left, everything else in **one** right-hand row.
            ///
            /// The touch layout stacks two pills here because a phone cannot fit
            /// five targets across next to a back button. A Mac window can, and a
            /// single row is what the platform expects.
            private var catalystTopCluster: some View {
                VStack {
                    HStack(alignment: .center) {
                        CircleButton(systemImage: "arrow.left", action: onBack)
                        Spacer()
                        ControlPill {
                            audioMenu {
                                HStack(spacing: 4) {
                                    Text(engine.streamInfo.resolutionLabel ?? "UNK")
                                        .font(.title3.weight(.semibold))
                                    Image(systemName: "chevron.down")
                                        .font(.body.weight(.semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .frame(height: 44)
                            }
                            audioMenu {
                                Image(systemName: "speaker.wave.2")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                            }
                            airPlayControl
                            PillButton(systemImage: "tv.badge.wifi") {
                                model.pokeControls()  // TODO: channel guide
                            }
                            PillButton(systemImage: "ellipsis") {
                                model.pokeControls()  // TODO: overflow menu
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }

            /// Connecting state only — see the note at the call site.
            @ViewBuilder
            private var catalystCentreButton: some View {
                if case .playing = model.state {
                    EmptyView()
                } else if case .failed = model.state {
                    EmptyView()
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .tint(.white)
                }
            }

            /// Programme identity on the left, transport on the right, timeline
            /// underneath both.
            private var catalystBottomCluster: some View {
                VStack(spacing: 14) {
                    Spacer()
                    HStack(alignment: .bottom, spacing: 20) {
                        catalystProgramInfo
                        Spacer(minLength: 20)
                        HStack(spacing: 12) {
                            catalystPlayPause
                            ControlPill {
                                PillButton(systemImage: "heart") {
                                    model.pokeControls()  // TODO: favourites
                                }
                                PillButton(systemImage: "plus.rectangle.on.rectangle") {
                                    onMultiview()
                                }
                                subtitleMenu
                                audioMenu {
                                    Image(systemName: "waveform")
                                        .font(.title3)
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: 44)
                                }
                            }
                        }
                        // The transport must not move when a programme title
                        // wraps to two lines, so it never yields width.
                        .layoutPriority(1)
                    }
                    catalystTimeline
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }

            /// Play, pause, or *waiting* — three states, because the player has
            /// three.
            ///
            /// Showing the play glyph while the player is waiting for data reads
            /// as "stopped, press to resume", and pressing it then pauses the
            /// stream that was about to start. This is what made returning from
            /// AirPlay unreadable: a black picture and a play button, with no way
            /// to tell loading from stopped.
            @ViewBuilder
            private var catalystPlayPause: some View {
                if case .playing = model.state {
                    if engine.isBuffering {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .frame(width: 56, height: 56)
                            .glassEffect(.regular, in: Circle())
                            .accessibilityLabel("Loading")
                    } else {
                        Button {
                            engine.playOrPause()
                            model.pokeControls()
                        } label: {
                            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .contentShape(Circle())
                        }
                        .contentTransition(.symbolEffect(.replace))
                        .glassEffect(.regular.interactive(), in: Circle())
                    }
                }
            }

            /// Channel, programme, synopsis and what the stream actually is.
            ///
            /// **The badges report only what the pipeline measured.** Resolution,
            /// frame rate and channel count come from `streamInfo` and are absent
            /// until the stream declares them, rather than being filled in with
            /// plausible defaults.
            private var catalystProgramInfo: some View {
                HStack(alignment: .bottom, spacing: 12) {
                    if let logoURL {
                        AsyncImage(url: logoURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Color.clear
                        }
                        .frame(width: 56, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.channelName)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))

                        if let program = model.currentProgram {
                            Text(program.displayTitle)
                                .font(.title.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            if let synopsis = program.programDescription, !synopsis.isEmpty {
                                Text(synopsis)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.75))
                                    .lineLimit(2)
                                    .frame(maxWidth: 520, alignment: .leading)
                            }
                        }

                        HStack(spacing: 6) {
                            ForEach(catalystBadges, id: \.self) { badge in
                                Text(badge)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .shadow(radius: 6)
            }

            private var catalystBadges: [String] {
                var badges = ["DISPATCHARR"]
                let info = engine.streamInfo
                if let resolution = info.resolutionLabel { badges.append(resolution) }
                if let rate = info.frameRateLabel { badges.append(rate.uppercased()) }
                if let audio = info.audioLabel { badges.append(audio.uppercased()) }
                return badges
            }

            /// The same read-only programme timeline, with the LIVE marker moved
            /// onto the playhead.
            ///
            /// **The badge is positioned, not spaced.** It used to sit between two
            /// `Spacer()`s, which pins it to the centre of the row and makes it
            /// read as a label for the programme rather than for the moment
            /// playback is at. Riding the thumb is the whole point of the change,
            /// so its x is computed from `model.progress` and then clamped by its
            /// own measured width so it cannot hang off either end.
            @ViewBuilder
            private var catalystTimeline: some View {
                if let program = model.currentProgram {
                    VStack(spacing: 6) {
                        Slider(value: .constant(model.progress), in: 0...1)
                            .tint(.white)
                            .allowsHitTesting(false)
                            .accessibilityRepresentation {
                                ProgressView(value: model.progress)
                                    .accessibilityLabel("Programme progress")
                            }

                        ZStack(alignment: .leading) {
                            HStack(spacing: 12) {
                                Text(program.startTime, style: .time)
                                Spacer(minLength: 40)
                                if let next = model.nextProgram {
                                    Text("\(next.startTime.formatted(date: .omitted, time: .shortened)) - \(next.displayTitle)")
                                        .lineLimit(1)
                                        .foregroundStyle(.white.opacity(0.75))
                                } else {
                                    Text(program.endTime, style: .time)
                                }
                            }

                            // **Not gated on `program.isLive`.** That flag is the
                            // EPG's "this is a live event" marker — true for a
                            // ball game, false for a repeat — and it is the wrong
                            // question here. This badge marks where the playhead
                            // is on a channel that is live by construction:
                            // `currentProgram` is the programme airing *now*. The
                            // gate meant the marker vanished on most programmes,
                            // which is exactly when a viewer wants to know how
                            // far behind the edge they are.
                            liveBadge(for: program)
                                .onGeometryChange(for: CGFloat.self) { proxy in
                                    proxy.size.width
                                } action: { width in
                                    liveBadgeWidth = width
                                }
                                .offset(x: liveBadgeOffset)
                        }
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.white)
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        timelineWidth = width
                    }
                }
            }

            private func liveBadge(for program: Program) -> some View {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 0.886, green: 0.294, blue: 0.290))
                        .frame(width: 10, height: 10)
                    Text("LIVE")
                        .foregroundStyle(Color(red: 0.886, green: 0.294, blue: 0.290))
                    Text(Date.now, style: .time)
                        .foregroundStyle(.white)
                }
            }

            /// Where the badge sits, in points from the row's leading edge.
            ///
            /// `thumbInset` is half a `Slider` thumb: the thumb's centre travels
            /// between `inset` and `width - inset`, not between 0 and `width`, so
            /// interpolating across the full width drifts further out of line the
            /// closer playback gets to either end.
            private var liveBadgeOffset: CGFloat {
                let thumbInset: CGFloat = 11
                guard timelineWidth > liveBadgeWidth, liveBadgeWidth > 0 else { return 0 }

                let travel = timelineWidth - thumbInset * 2
                let head = thumbInset + travel * model.progress
                let ideal = head - liveBadgeWidth / 2
                return min(max(0, ideal), timelineWidth - liveBadgeWidth)
            }

        #endif

        // MARK: - Timeline

        /// The EPG programme's timeline, not the stream's.
        ///
        /// Read-only by design: the labels are the programme's start and end from
        /// the guide, and the fill is how far through it we are. It is
        /// deliberately *not* wired to `seek` — the two timelines do not line up,
        /// and a scrubber that moves the picture somewhere other than where the
        /// thumb says is worse than one that does not move at all.
        ///
        /// **Now the stock `Slider` rather than a hand-built capsule.** There is
        /// no separate "glass slider style" in iOS 26 — the system `Slider` *is*
        /// Liquid Glass, so adopting it is how you get the real material,
        /// including its motion and its light response, for free.
        ///
        /// Two deliberate choices follow from it being read-only:
        ///
        /// * `.allowsHitTesting(false)` rather than `.disabled(true)`. Disabling
        ///   would grey it out; this keeps the enabled appearance while making it
        ///   inert.
        /// * `.accessibilityRepresentation` swaps in a `ProgressView` for
        ///   assistive tech. Visually it is a slider, but announcing it as an
        ///   *adjustable* control would promise VoiceOver users an interaction
        ///   that does not exist.
        ///
        /// If the thumb reads as a false affordance, `.sliderThumbVisibility(.hidden)`
        /// (new in iOS 26) removes it in one line.
        @ViewBuilder
        private var timeline: some View {
            if let program = model.currentProgram {
                VStack(spacing: 6) {
                    Slider(value: .constant(model.progress), in: 0...1)
                        .tint(.white)
                        .allowsHitTesting(false)
                        .accessibilityRepresentation {
                            ProgressView(value: model.progress)
                                .accessibilityLabel("Programme progress")
                        }

                    HStack {
                        Text(program.startTime, style: .time)
                        Spacer()
                        if program.isLive {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(red: 0.886, green: 0.294, blue: 0.290))
                                    .frame(width: 10, height: 10)
                                Text("LIVE")
                                    .foregroundStyle(Color(red: 0.886, green: 0.294, blue: 0.290))
                            }
                        }
                        Spacer()
                        Text(program.endTime, style: .time)
                    }
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white)
                }
            }
        }

        /// Rotates to landscape and back.
        ///
        /// `requestGeometryUpdate` is the modern replacement for the
        /// `UIDevice.setValue(_:forKey:)` hack — that one worked by poking a
        /// private setter and is exactly the kind of thing App Review notices.
        private func toggleFullScreen() {
            guard
                let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            else { return }

            let isLandscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
            let mask: UIInterfaceOrientationMask = isLandscape ? .portrait : .landscapeRight
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }

    // MARK: - Building blocks

    /// The rounded slab the controls sit on.
    ///
    /// A `ViewBuilder`-based container rather than a modifier so the pill sizes
    /// to its contents and each button keeps a full 44pt hit target inside it.
    struct ControlPill<Content: View>: View {
        @ViewBuilder let content: Content

        var body: some View {
            // The glass goes on the *pill*, not on each button inside it.
            // Applying `glassEffect` per child gives every glyph its own capsule
            // and the row stops reading as one control cluster.
            HStack(spacing: 2) {
                content
            }
            .padding(.horizontal, 6)
            .glassEffect(.regular, in: Capsule())
        }
    }

    /// A menu row with an optional checkmark.
    ///
    /// `Label(_:systemImage:)` with an empty string renders a blank icon slot
    /// and misaligns the text, so the checked and unchecked cases are separate.
    struct Label2: View {
        let title: String
        let checked: Bool

        init(_ title: String, checked: Bool) {
            self.title = title
            self.checked = checked
        }

        var body: some View {
            if checked {
                SwiftUI.Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    struct PillButton: View {
        let systemImage: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.white)
                    // 44pt is Apple's minimum touch target. Glyphs this small
                    // need the frame to reach it — without it these are ~24pt
                    // and genuinely hard to hit in motion.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    struct CircleButton: View {
        let systemImage: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    // `.interactive()` makes the glass respond to touch — it
                    // flexes and brightens under the finger. Worth it on a lone
                    // button that is its own target; the pills get the plain
                    // `.regular` because their children own the interaction.
                    .glassEffect(.regular.interactive(), in: Circle())
            }
        }
    }

#endif

import AVFoundation
import SwiftUI

#if os(tvOS)

    /// The ten-foot player overlay: programme information down the left, a row
    /// of circular controls on the right, and a segmented timeline beneath both.
    ///
    /// Replaces `AVPlayerViewController`'s own controls, which is why the player
    /// now draws into a bare `AVPlayerLayer` on tvOS as well as iOS — a
    /// controller with `showsPlaybackControls = false` still owns gestures and
    /// still insets the layout.
    struct TVPlayerControlsView: View {
        @Bindable var model: PlayerModel
        let engine: AVPlayerEngine
        let channel: Channel
        let logoURL: URL?
        let palette: LogoPalette?

        /// Which control the remote is on. Also the focus target the overlay
        /// restores to whenever it reappears.
        @FocusState private var focusedControl: ControlID?

        enum ControlID: Hashable {
            case quality, favourite, multiview, pictureInPicture, subtitles, audio, more
        }

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                scrim
                content
            }
            .opacity(model.controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: model.controlsVisible)
            // Hidden controls must not hold focus, or the remote is stuck on an
            // invisible row and the video appears frozen to input.
            .allowsHitTesting(model.controlsVisible)
            .focusSection()
            .onChange(of: model.controlsVisible) { _, visible in
                if visible, focusedControl == nil { focusedControl = .subtitles }
            }
        }

        /// Darkest at the left and bottom, where the text and controls sit.
        ///
        /// Two gradients rather than one: the information panel needs contrast
        /// down the *left* edge, and the timeline needs it along the *bottom*.
        /// A single diagonal ramp dims the middle of the picture without helping
        /// either.
        private var scrim: some View {
            ZStack {
                // Deliberately heavy. The first pass used a much lighter ramp
                // and the description was unreadable over a bright shot — a
                // baseball field in daylight is close to white, and body text at
                // 0.25 black over it has almost no contrast. Chrome over
                // arbitrary video has to assume the worst frame, not an average
                // one.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.95), location: 0.0),
                        .init(color: .black.opacity(0.85), location: 0.30),
                        .init(color: .black.opacity(0.35), location: 0.62),
                        .init(color: .clear, location: 0.85),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.25), location: 0.55),
                        .init(color: .black.opacity(0.85), location: 0.85),
                        .init(color: .black.opacity(0.95), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }

        private var content: some View {
            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 0)

                HStack(alignment: .bottom, spacing: 40) {
                    infoPanel
                    Spacer(minLength: 40)
                    controlRow
                }

                TVPlayerTimeline(model: model)
            }
            .padding(.horizontal, Layout.screenMarginH)
            .padding(.bottom, Layout.screenMarginV)
        }

        // MARK: - Information

        private var infoPanel: some View {
            VStack(alignment: .leading, spacing: 12) {
                logoPlate

                Text(channel.displayName)
                    .font(.headline.pointSize(54))
                    .foregroundStyle(.white.opacity(0.85))

                Text(model.currentProgram?.displayTitle ?? channel.displayName)
                    .font(.system(size: 48, weight: .bold))
                    .lineLimit(2)

                if let program = model.currentProgram {
                    Text("\(program.startTime.clockLabel) - \(program.endTime.clockLabel)")
                        .font(.title3.pointSize(32))
                        .foregroundStyle(.white.opacity(0.85))

                    if let description = program.programDescription, !description.isEmpty {
                        Text(description)
                            .font(.title3.pointSize(32))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(3)
                    }
                }

                badges
            }
            .foregroundStyle(.white)
            // Half the screen, so a long description cannot run under the
            // control row.
            .frame(maxWidth: 1000, alignment: .leading)
        }

        private var logoPlate: some View {
            GuideLogoTile(
                channel: channel,
                logoURL: logoURL,
                palette: palette,
                width: 190,
                height: 190 / kLogoPlateAspect + GuideLogoTile.verticalInset
            )
            .padding(.bottom, 8)
        }

        /// Stream facts, and only the ones the pipeline actually reports.
        ///
        /// A field the stream does not declare is omitted rather than filled in
        /// with something plausible — a badge saying STEREO on a stream that
        /// never said so is worse than no badge.
        private var badges: some View {
            let info = engine.streamInfo
            let labels = [
                "DISPATCHARR",
                info.resolutionLabel,
                info.frameRateLabel,
                info.audioLabel,
            ].compactMap(\.self)

            return HStack(spacing: 10) {
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.top, 6)
        }

        // MARK: - Controls

        private var controlRow: some View {
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 18) {
                    qualityPill
                    circle(.favourite, "heart") { /* TODO: favourites */  }
                    circle(.multiview, "plus.rectangle.on.rectangle") { /* TODO: multiview */  }
                    circle(.pictureInPicture, "pip") { /* TODO: PiP on tvOS */  }
                    subtitlesMenu
                    audioMenu
                    circle(.more, "ellipsis") { /* TODO: overflow */  }
                }
            }
        }

        /// Reports the resolution; does not switch it.
        ///
        /// Deliberately not a picker: the stream is a single-variant media
        /// playlist, so there is nothing to choose between. Showing a menu with
        /// one entry would imply a control that does not exist.
        private var qualityPill: some View {
            Text(engine.streamInfo.resolutionLabel ?? "UNK")
                .font(.title3.weight(.semibold).pointSize(24))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .frame(height: 68)
                .glassEffect(.regular, in: Capsule())
        }

        private func circle(
            _ id: ControlID,
            _ symbol: String,
            action: @escaping () -> Void
        ) -> some View {
            Button {
                action()
                model.pokeControls()
            } label: {
                Image(systemName: symbol)
                    .font(.title2.pointSize(24))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
            }
            .buttonStyle(TVControlButtonStyle())
            .focused($focusedControl, equals: id)
        }

        private var subtitlesMenu: some View {
            Menu {
                if let group = engine.subtitleGroup, !group.options.isEmpty {
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
                    .font(.title2.pointSize(24))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
            }
            .menuStyle(.button)
            .buttonStyle(TVControlButtonStyle())
            .focused($focusedControl, equals: .subtitles)
            .accessibilityLabel("Subtitles")
        }

        private var audioMenu: some View {
            Menu {
                if let group = engine.audioGroup, !group.options.isEmpty {
                    ForEach(group.options, id: \.self) { option in
                        Button(option.displayName) {
                            engine.select(option, in: group)
                            model.pokeControls()
                        }
                    }
                } else {
                    Text("No alternate audio")
                }
            } label: {
                Image(systemName: "waveform")
                    .font(.title2.pointSize(24))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
            }
            .menuStyle(.button)
            .buttonStyle(TVControlButtonStyle())
            .focused($focusedControl, equals: .audio)
            .accessibilityLabel("Audio track")
        }
    }

    /// Focus treatment for a circular player control: glass, with a ring and a
    /// lift when the remote is on it.
    struct TVControlButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            ControlBody(configuration: configuration)
        }

        struct ControlBody: View {
            let configuration: Configuration
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .glassEffect(
                        isFocused ? .regular.interactive().tint(.red.opacity(0.4)) : .regular.interactive(),
                                            in: Circle()
                                        )                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
                    .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            }
        }
    }

    /// The programme timeline: the current programme, then the next one.
    ///
    /// Read-only, for the same reason as the phone's: the bar shows the *EPG's*
    /// schedule, which does not line up with AVPlayer's seekable range, and a
    /// scrubber that moves the picture somewhere other than where the thumb says
    /// is worse than one that does not move.
struct TVPlayerTimeline: View {
        @Bindable var model: PlayerModel

        private let barHeight: CGFloat = 8
        private let gap: CGFloat = 12

        var body: some View {
            VStack(spacing: 14) {
                bar
                labels
            }
        }

        private var bar: some View {
            GeometryReader { geometry in
                let split = segmentWidths(total: geometry.size.width)
                HStack(spacing: gap) {
                    // Current programme: elapsed, then remaining.
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3))
                        Capsule()
                            .fill(.white)
                            .frame(width: split.current * model.progress)
                    }
                    .frame(width: split.current)

                    if split.next > 0 {
                        // Distinct enough from the current programme's unplayed
                        // remainder (0.3) to read as a different block rather
                        // than more of the same bar.
                        Capsule()
                            .fill(.white.opacity(0.16))
                            .frame(width: split.next)
                    }
                }
            }
            .frame(height: barHeight)
        }

        /// Widths for the current and next programme, in proportion to their
        /// durations.
        private func segmentWidths(total: CGFloat) -> (current: CGFloat, next: CGFloat) {
            guard let current = model.currentProgram else { return (total, 0) }
            guard let next = model.nextProgram else { return (total, 0) }

            let currentSeconds = max(current.duration, 1)
            let nextSeconds = max(next.duration, 1)
            let usable = max(total - gap, 1)
            let currentShare = currentSeconds / (currentSeconds + nextSeconds)
            let currentWidth = usable * currentShare
            return (currentWidth, usable - currentWidth)
        }

        private var labels: some View {
            HStack {
                Text(model.currentProgram?.startTime.clockLabel ?? "")
                    .foregroundStyle(.white.opacity(0.85))
                    .font(.title3.pointSize(24))

                Spacer()

                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(red: 0.886, green: 0.294, blue: 0.290))
                        .frame(width: 12, height: 12)
                    Text(model.tick.clockLabel)
                        .font(.title3.pointSize(24))
                        .foregroundStyle(.white)
                }

                Spacer()

                if let next = model.nextProgram {
                    Text("\(next.startTime.clockLabel) - \(next.displayTitle)")
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(maxWidth: 520, alignment: .trailing)
                        .font(.title3.pointSize(24))
                } else {
                    Text(model.currentProgram?.endTime.clockLabel ?? "")
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .font(.title3)
        }
    }

#Preview {
    // 1. Anchor fake times around right now
    let now = Date.now
    let oneHourAgo = now.addingTimeInterval(-3600)
    let oneHourFromNow = now.addingTimeInterval(3600)
    let twoHoursFromNow = now.addingTimeInterval(7200)
    
    // 2. Create mock programs using your exact Program struct
    let currentProgram = Program(
        id: 101,
        title: "Local News at 6",
        startTime: oneHourAgo,
        endTime: oneHourFromNow,
        subTitle: "Evening Update",
        programDescription: "The latest top stories, weather, and sports.",
        tvgID: "local.news",
        iconURL: "https://unsplash.com/photos/area-51-alien-center-building-yaf0Qhab7Hw",
        season: nil,
        episode: nil,
        isNew: true,
        isLive: true,
        isPremiere: false,
        isFinale: false
    )
    
    let nextProgram = Program(
        id: 102,
        title: "Primetime Movie",
        startTime: oneHourFromNow,
        endTime: twoHoursFromNow,
        subTitle: nil,
        programDescription: "An action-packed blockbuster.",
        tvgID: "movie.channel",
        iconURL: nil,
        season: nil,
        episode: nil,
        isNew: false,
        isLive: false,
        isPremiere: false,
        isFinale: false
    )
    
    // 3. Initialize the PlayerModel
    let mockModel = PlayerModel(
        channelName: "Demo Channel",
        streamURL: URL(string: "https://demo.local/stream.m3u8"),
        programs: [currentProgram, nextProgram]
    )
    
    // 4. Build the view (using your new Channel.previewMock)
    ZStack {
        // Fake video background
        Color(white: 0.15)
            .ignoresSafeArea()
            
        TVPlayerControlsView(
            model: mockModel,
            engine: mockModel.avEngine ?? AVPlayerEngine(),
            channel: .previewMock,
            logoURL: nil,
            palette: nil
        )
    }
}
#endif

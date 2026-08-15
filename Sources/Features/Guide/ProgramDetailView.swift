import SwiftUI

/// Details for one programme, presented as a sheet from the guide.
///
/// Takes a `GuideSelection` rather than a channel and a programme separately:
/// the two travel together from the tap that opened this, and splitting them
/// into two parameters invites a call site that pairs a programme with the wrong
/// channel.
struct ProgramDetailView: View {
    let selection: GuideSelection
    let logoURL: URL?
    var palette: LogoPalette?

    /// Play this channel. The sheet dismisses itself first — see `playButton`.
    let onPlay: (Channel) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Ticks so the progress bar and the "on now" state stay honest while the
    /// sheet is open. Same cadence as the guide's own timer, and for the same
    /// reason: a programme block is an hour wide, so anything finer is wasted.
    @State private var now = Date.now

    private var program: Program { selection.program }
    private var channel: Channel { selection.channel }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if program.isAiring(at: now) {
                        progress
                    }
                    if !description.isEmpty {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    playButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(program.displayTitle)
            .inlineNavigationTitle()
            #if !os(tvOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            #endif
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                now = .now
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            GuideLogoTile(
                channel: channel,
                logoURL: logoURL,
                palette: palette,
                width: 96,
                height: 96 / kGuideLogoAspect
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(channel.displayName)
                    .font(.headline)

                Text(timeRange)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Only what this programme actually carries. An empty row of
                // placeholders reads as missing data rather than as absent
                // metadata, and most EPG entries have none of these.
                HStack(spacing: 6) {
                    if program.isAiring(at: now) { badge("On now", tint: .red) }
                    if program.isNew { badge("New", tint: .accentColor) }
                    if program.isPremiere { badge("Premiere", tint: .accentColor) }
                    if program.isFinale { badge("Finale", tint: .accentColor) }
                    if let episode = program.episodeLabel { badge(episode, tint: .secondary) }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: program.progress(at: now))
            Text(remaining)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var playButton: some View {
        Button {
            // **Dismiss first, then hand back the channel.** Presenting the
            // player while this sheet is still up puts two presentations in
            // flight at once, and the second is dropped.
            dismiss()
            onPlay(channel)
        } label: {
            Label("Watch \(channel.displayName)", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        // Plain glass at rest, accent-tinted on hover or focus — the style owns
        // both the hover state and the padding, so nothing here has to.
        .buttonStyle(HoverGlassButtonStyle())
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.2), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }

    // MARK: - Text

    /// sub_title if there is one, else the programme description, else nothing.
    /// Never both — they are usually the same sentence on this EPG.
    private var description: String {
        let subtitle = program.displaySubTitle
        if !subtitle.isEmpty { return subtitle }
        return (program.programDescription ?? "").strippedOfNonASCII
    }

    private var timeRange: String {
        "\(program.startTime.clockLabel) – \(program.endTime.clockLabel)"
    }

    private var remaining: String {
        let left = program.endTime.timeIntervalSince(now)
        guard left > 0 else { return "Ended" }
        let minutes = Int((left / 60).rounded(.up))
        return minutes == 1 ? "1 minute left" : "\(minutes) minutes left"
    }
}

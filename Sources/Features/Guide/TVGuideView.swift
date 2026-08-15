import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// A horizontally-scrolling TV guide grid.
///
/// Rows are channels, the x axis is time. The logo column is pinned; the
/// programme lane scrolls under it, and each block carries a pinned header —
/// channel name and start time — that stays put while the block moves, so a
/// divider passing over it slices the text rather than the label jumping.
///
/// **Not virtualised**, matching the Flutter original: every row and every block
/// is built up front. `maxRows` is what bounds the work. A `LazyVStack` would
/// help the rows, but the blocks inside a row are absolutely positioned across a
/// very wide canvas, so real virtualisation needs a 2D viewport either way.
struct TVGuideView: View {
    let channels: [Channel]
    let guide: EPGGuide
    var logoURLFor: (Channel) -> URL? = { _ in nil }
    /// The pinned logo column was tapped — play the channel.
    var onLogoTap: (Channel) -> Void = { _ in }

    /// A programme block was tapped.
    ///
    /// Carries the *programme* as well as the channel, because "which block" is
    /// the whole question a detail sheet has to answer and the channel alone
    /// cannot say it — a row holds a day of them.
    var onProgramTap: (GuideSelection) -> Void = { _ in }
    var palette: LogoPalette?
    var maxRows: Int?

    /// Overrides the row height for this instance. Nil takes it from the window
    /// — see `resolvedRowHeight`.
    var rowHeight: CGFloat?

    /// Width of the pinned logo column. Defaults to whatever makes the tile the
    /// same shape as a Continue Watching card at this row height.
    var logoWidth: CGFloat?

    /// Overrides the time axis for this instance. Nil takes it from the window.
    var pixelsPerMinute: CGFloat?

    /// Margin between the lane's closed right edge and its container.
    ///
    /// Owned here rather than left to call sites, because it is now part of the
    /// lane's own geometry: the clip shape ends where this begins. The screen
    /// margin by default, so the guide's right edge lines up with the left edge
    /// of everything else on the page.
    var trailingInset: CGFloat = Layout.screenMarginH

    /// Regular width — iPad full screen, a wide Mac window — draws the guide a
    /// step larger. A no-op on tvOS, which `Metrics.resolve` ignores.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var metrics: Metrics {
        .resolve(isRegularWidth: horizontalSizeClass == .regular)
    }

    /// The row height actually drawn: the caller's override, else the window's.
    private var resolvedRowHeight: CGFloat { rowHeight ?? metrics.guideRowHeight }

    private var resolvedPixelsPerMinute: CGFloat {
        pixelsPerMinute ?? metrics.guidePixelsPerMinute
    }

    /// The logo column's width, derived from the row height so the tile keeps
    /// `kGuideLogoAspect`.
    ///
    /// Deriving rather than storing is what keeps the column and the rows in
    /// step: change the row height and the column follows, and the programme
    /// lane — which is positioned off this value — follows both. It is also why
    /// a taller row on iPad is a *bigger logo tile* without anything else being
    /// asked to grow.
    private var resolvedLogoWidth: CGFloat {
        if let logoWidth { return logoWidth }
        let plateHeight = resolvedRowHeight - GuideLogoTile.verticalInset
        return plateHeight * kGuideLogoAspect + GuideLogoTile.horizontalInset
    }

    /// How far the programme lane tucks under the logo column.
    private let overlap: CGFloat = 14

    /// Narrowest a block may be and still be drawn.
    ///
    /// Comfortably wider than the 2pt divider and than the corner radius, so
    /// every block that survives has a clip shape with real area to clip
    /// against — see the note in `laneRow`.
    private let minimumBlockWidth: CGFloat = 6


    /// Ticks the "now" marker without touching anything else.
    @State private var now = Date.now
    @State private var scroll = GuideScrollPosition()
    @State private var scrollPosition = ScrollPosition()
    
    @State private var isLogoHovered: Bool = false

    /// The app is pinned dark; the guide's tints are composited over this.
    private let surface = RGBColor(r: 0x0E, g: 0x0E, b: 0x10)

    private var rows: [GuideRow] {
        let limited = maxRows.map { Array(channels.prefix($0)) } ?? channels
        return limited.map { GuideRow(channel: $0, programs: guide.programs(for: $0)) }
    }

    /// Earliest programme start across all rows, and total lane width.
    private var timeline: (start: Date, width: CGFloat) {
        var earliest: Date?
        var latest: Date?
        for row in rows {
            for program in row.programs {
                if earliest == nil || program.startTime < earliest! { earliest = program.startTime }
                if latest == nil || program.endTime > latest! { latest = program.endTime }
            }
        }
        let start = earliest ?? .now
        let end = latest ?? start.addingTimeInterval(4 * 3600)
        let minutes = end.timeIntervalSince(start) / 60
        return (start, max(1, CGFloat(minutes) * resolvedPixelsPerMinute))
    }

    private var hasPrograms: Bool { rows.contains { !$0.programs.isEmpty } }

    var body: some View {
        let rows = self.rows
        if rows.isEmpty {
            emptyState("No guide data")
        } else if !hasPrograms {
            // Channels resolved but nothing joined to them. Silently drawing
            // bare logos hides the cause, so name which failure mode this is.
            emptyState(emptyLaneMessage)
        } else {
            grid(rows: rows)
        }
    }

    private func grid(rows: [GuideRow]) -> some View {
        let timeline = self.timeline

        return ZStack(alignment: .topLeading) {
            // Programme lane, tucked under the logo column by `overlap`.
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        laneRow(row, timeline: timeline)
                    }
                }
                .frame(width: timeline.width, alignment: .topLeading)
            }
            // `ScrollPosition` scrolls to an exact content offset, which is what
            // this needs — the target is a *time*, not a view.
            //
            // The first attempt used `ScrollViewReader` with a zero-width marker
            // pushed to the right time by `.offset(x:)`. That silently does
            // nothing useful: `.offset` is a render-time transform, so the
            // marker's *layout* position is still x = 0 and `scrollTo` dutifully
            // scrolled to the start. Anchoring on a view only works when the
            // view genuinely lives where you want to land.
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, newValue in
                scroll.x = newValue
            }
            // Keyed on the timeline's start, not a one-shot `onAppear`.
            //
            // `onAppear` + a `didInitialScroll` flag looked like the faithful
            // port of Flutter's `_didInitialScroll`, but it raced: the row budget
            // is derived from the page size, which is zero on the first layout
            // pass, so the guide briefly holds one row and a different timeline.
            // The scroll fired against *that* timeline, the flag latched, and the
            // real content landed at x = 0 with no retry.
            //
            // The start time only moves when the data does, so keying on it
            // re-positions exactly when the timeline is actually different and
            // still never yanks the user back mid-browse.
            .task(id: timeline.start) {
                // One turn of the run loop so the content is laid out —
                // `scrollTo` on a scroll view that has no extent yet is a no-op.
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                scrollPosition.scrollTo(x: nowOffset(timeline: timeline))
            }
            // **Clipped to the rows, before the leading padding is applied.**
            //
            // A scroll view clips to its own bounds by default, which is why the
            // lane used to end in a hard vertical cut at the screen edge. This
            // replaces that with a rounded end per row, so a programme that
            // continues past the viewport reads as *continuing* rather than as
            // having been sliced off.
            //
            // Order matters: the clip has to land on the scroll view itself, so
            // its rect is the lane. Applied after `.padding(.leading, …)` the
            // rect would include the logo column and every bar would be rounded
            // 76pt to the left of where it is drawn.
            .clipShape(GuideLaneShape(rowCount: rows.count, rowHeight: resolvedRowHeight))
            .padding(.leading, resolvedLogoWidth - overlap)

            // Pinned logo column, drawn last so it sits over the lane.
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    let tile = GuideLogoTile(
                        channel: row.channel,
                        logoURL: logoURLFor(row.channel),
                        palette: palette,
                        width: resolvedLogoWidth,
                        height: resolvedRowHeight
                    )

                    // **Tappable on iOS, inert on tvOS.**
                    //
                    // The column overlays the lane, so a focusable tile here
                    // would sit on top of every row's blocks and give the remote
                    // a second target in the same place — the kind of focus trap
                    // the project notes are full of. A pointer has no such
                    // problem: it clicks what it is over.
                    //
                    // Wrapping the whole tile, not the artwork inside it, so the
                    // plate and the fallback initial are clickable too — a
                    // channel with no logo would otherwise have nothing to hit.
                    #if os(tvOS)
                        tile
                    #else
                        Button {
                            onLogoTap(row.channel)
                        } label: {
                            tile
                        }
                        // `.plain` keeps the tile exactly as drawn. The hover
                        // feedback is the tile's own scale — `cardButtonStyle()`
                        // would stack a second one on top of it.
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(row.channel.displayName)")
                    #endif
                }
            }
        }
        // Room between the closed edge and whatever is beyond it. Without a
        // margin the rounded ends sit flush against the screen, which looks like
        // a rendering artefact rather than a deliberate edge.
        .padding(.trailing, trailingInset)
        .frame(height: CGFloat(rows.count) * resolvedRowHeight)
        // One focus group for the grid. Without it, moving up out of the guide
        // can land on whatever is geometrically nearest rather than the section
        // above.
        .tvFocusSection()
        // One tick a minute advances the progress fill and the "airing" state.
        // Same cadence as the Flutter timer — a programme block is an hour wide,
        // so anything finer is wasted work.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                now = .now
            }
        }
    }

    private func laneRow(_ row: GuideRow, timeline: (start: Date, width: CGFloat)) -> some View {
        // `.offset` rather than layout position: blocks overlap the row's
        // leading edge conceptually (a programme can start before the timeline
        // window) and offsets do not participate in sizing, so the row keeps its
        // fixed width regardless of what is in it.
        // Measured once per row rather than per block: it is the same name on
        // every block in the row, and there can be dozens of them.
        let nameWidth = channelNameWidth(row.channel.displayName)

        return ZStack(alignment: .topLeading) {
            ForEach(row.programs) { program in
                let left = CGFloat(program.startTime.timeIntervalSince(timeline.start) / 60)
                    * resolvedPixelsPerMinute
                let blockWidth = CGFloat(program.duration / 60) * resolvedPixelsPerMinute
                // **Degenerate blocks are dropped, not drawn.**
                //
                // A programme with a tiny or zero duration — the EPG has them,
                // and at 8pt per minute a two-minute filler entry is 16pt while
                // a malformed one is 0 — becomes a block narrower than the 2pt
                // divider beside it. `max(0, width - 2)` then gives it a clip
                // shape with no area, and a shape with no area is not a
                // dependable clip: what leaks through is a sliver of the label's
                // white text, sitting in what looks like the gap between the two
                // real blocks either side of it.
                //
                // Nothing is lost by skipping them. A block this narrow cannot
                // show a title, a time, or a usable tap target.
                if blockWidth >= minimumBlockWidth {
                    GuideBlock(
                        program: program,
                        channel: row.channel,
                        channelNameWidth: nameWidth,
                        width: blockWidth,
                        leftOffset: left,
                        overlap: overlap,
                        surface: surface,
                        now: now,
                        scroll: scroll,
                        // Built here rather than inside `GuideBlock`, because
                        // this is the one place both the row's channel and the
                        // block's programme are already in hand.
                        onTap: {
                            onProgramTap(
                                GuideSelection(channel: row.channel, program: program)
                            )
                        }
                    )
                    .offset(x: left)
                }
            }
        }
        .frame(width: timeline.width, height: resolvedRowHeight, alignment: .topLeading)
        // Inert unless a parent animates the change that adds or removes the
        // row — which is only search today. The homepage and category guides
        // rebuild inside no transaction, so this costs them nothing.
        .transition(.opacity)
        // Each channel's lane is its own group, so left/right travels along one
        // channel's timeline instead of drifting diagonally between rows.
        .tvFocusSection()
    }

    /// Rendered width of a channel name in the header's own font.
    ///
    /// Needed as a *layout* input, not a readback: it is the floor the header's
    /// offset is clamped to, so it has to be known in the same pass the header
    /// is positioned in. A `GeometryReader` reports a frame late, which at 120Hz
    /// would be a permanent shimmer rather than a glitch you catch once.
    private func channelNameWidth(_ name: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: metrics.guideSubtitleFont, weight: .semibold)
        return (name as NSString).size(withAttributes: [.font: font]).width
    }

    private func nowOffset(timeline: (start: Date, width: CGFloat)) -> CGFloat {
        let minutes = Date.now.timeIntervalSince(timeline.start) / 60
        return max(0, CGFloat(minutes) * resolvedPixelsPerMinute - 24)
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding()
            .frame(maxWidth: .infinity, minHeight: 160)
    }

    /// Names the specific failure so an empty guide is actionable.
    private var emptyLaneMessage: String {
        if guide.hasProgramsWithoutTvgIDs {
            return """
                The EPG returned \(guide.totalPrograms) programmes, but none \
                carry a tvg_id to match channels on.
                """
        }
        if guide.isEmpty {
            return """
                The EPG returned no programmes.
                Check that an EPG source is configured and has been imported.
                """
        }
        return """
            None of these channels are linked to EPG data.
            Set each channel's EPG source in Dispatcharr, or run Match EPG.
            """
    }
}

/// The lane's clip: one rounded bar per row, stacked.
///
/// **Not a single rounded rectangle around the whole lane.** That would round
/// only the top and bottom rows' outer corners and leave every row between them
/// cut square — and rows are separated by `kGuideBlockVerticalInset`, so a
/// container-shaped clip would also paint across those gaps. A path made of one
/// rounded rect per row gives every row its own closed end.
///
/// **Trailing corners only.** The leading edge stays square so the lane runs
/// straight into the pinned logo column beside it. Rounding it would pinch the
/// bar in just before the tile and leave a sliver of background between the two,
/// which reads as a gap rather than as a row continuing off-screen — and the
/// lane deliberately tucks under the column by `overlap`, so a rounded leading
/// edge is cutting a corner nobody can see the far side of.
private struct GuideLaneShape: Shape {
    let rowCount: Int
    let rowHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<rowCount {
            let bar = CGRect(
                x: rect.minX,
                y: rect.minY + CGFloat(index) * rowHeight + kGuideBlockVerticalInset,
                width: rect.width,
                height: rowHeight - kGuideBlockVerticalInset * 2
            )
            // `UnevenRoundedRectangle` rather than `Path.addRoundedRect`, which
            // takes one corner size for all four and cannot express this.
            path.addPath(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: kGuideBlockCornerRadius,
                    topTrailingRadius: kGuideBlockCornerRadius,
                    style: .continuous
                )
                .path(in: bar)
            )
        }
        return path
    }
}

/// A programme the user picked out of the guide, and the channel it is on.
///
/// **`Identifiable`, and that is the point.** It is what `.sheet(item:)` binds
/// to, so the selection *is* the presentation state — there is no separate
/// `Bool` that can disagree with it. A `showingDetails = true` alongside a
/// `selectedProgram` is two sources of truth for one fact, and they come apart
/// in both directions: a sheet with nothing in it, or a selection with no sheet.
///
/// The id composes channel, programme and start time because a programme id is
/// not unique across airings — the same episode repeats, and two channels can
/// carry the same one at once.
struct GuideSelection: Identifiable, Hashable {
    let channel: Channel
    let program: Program

    var id: String {
        "\(channel.id)-\(program.id)-\(program.startTime.timeIntervalSince1970)"
    }
}

/// One rendered row: a channel and its programmes.
struct GuideRow: Identifiable {
    let channel: Channel
    let programs: [Program]

    var id: Int { channel.id }
}

/// One programme block.
///
/// Its own `View` type rather than a helper method so SwiftUI can skip
/// re-rendering blocks whose inputs did not change — which matters here, because
/// there can be hundreds of them.
struct GuideBlock: View {
    let program: Program
    let channel: Channel

    /// Measured by the row — the floor for the header's offset. See
    /// `GuideBlockLabel.headerPin`.
    let channelNameWidth: CGFloat

    let width: CGFloat
    let leftOffset: CGFloat
    let overlap: CGFloat
    let surface: RGBColor
    let now: Date
    let scroll: GuideScrollPosition
    let onTap: () -> Void

    private var colors: (rest: RGBColor, active: RGBColor, foreground: Color) {
        // Seeded per *programme*, not per channel: adjacent blocks in a row get
        // different hues, which is what makes the grid readable at a glance.
        let seed = program.title.isEmpty ? (channel.effectiveTvgID ?? "") : program.title
        let tint = GuideTint.tint(seed: seed, surface: surface)
        let rest = tint.blended(alpha: GuideTint.restAlpha, over: surface)
        let active = tint.blended(alpha: GuideTint.activeAlpha, over: surface)
        return (rest, active, active.foreground)
    }

    var body: some View {
        let colors = self.colors
        let progress = program.progress(at: now)

        Button(action: onTap) {
            ZStack(alignment: .leading) {
                colors.rest.color
                // Elapsed portion of the programme.
                GeometryReader { geometry in
                    colors.active.color
                        .frame(width: geometry.size.width * progress)
                }
                GuideBlockLabel(
                    program: program,
                    channel: channel,
                    channelNameWidth: channelNameWidth,
                    airing: program.isAiring(at: now),
                    foreground: colors.foreground,
                    width: width,
                    leftOffset: leftOffset,
                    overlap: overlap,
                    scroll: scroll
                )
                // Text, and nothing but. Letting it take the pointer is what put
                // a block's hover on its *neighbour*: `headerPin` runs negative
                // down to `headerFloor`, so every block's header hangs up to a
                // channel-name to the left of the block it belongs to.
                .allowsHitTesting(false)
            }
            .frame(width: max(0, width - 2), height: nil)
            // `clipped()` as well as `clipShape`, and before it. The label is
            // `fixedSize`, so it is routinely wider than the block it sits in —
            // a rectangular clip to the bounds is cheap and unconditional, and
            // leaves the rounded shape to do nothing but round the corners.
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: kGuideBlockCornerRadius))
            // **Clipping is a drawing operation, not an interaction one.**
            //
            // Neither `clipped()` nor `clipShape()` narrows hit testing, so
            // without this the overhanging header still answers the pointer from
            // outside the block — invisibly, over whichever block is actually
            // there. `contentShape` is what makes the hit region agree with the
            // visible one.
            .contentShape(Rectangle())
            .padding(.vertical, kGuideBlockVerticalInset)
            .padding(.trailing, 2)
        }
        // Blocks are focusable so a remote or keyboard can reach them; the
        // Flutter version used InkWell for the same reason. An outline rather
        // than a lift, because blocks sit shoulder-to-shoulder.
        .guideBlockButtonStyle()
    }
}

/// The block's text, split out because it is the only thing that reads the
/// scroll offset.
///
/// Keeping this a separate `View` is what makes the `@Observable` scroll
/// position pay off: only these views re-evaluate while the lane scrolls.
struct GuideBlockLabel: View {
    let program: Program
    let channel: Channel
    let channelNameWidth: CGFloat
    let airing: Bool
    let foreground: Color
    let width: CGFloat
    let leftOffset: CGFloat
    let overlap: CGFloat
    let scroll: GuideScrollPosition

    /// Type steps up with the row height it sits inside — see `Metrics`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var metrics: Metrics {
        .resolve(isRegularWidth: horizontalSizeClass == .regular)
    }

    /// How much of this block has scrolled in behind the pinned logo column.
    ///
    /// Negative for a block still fully to the right of the viewport's leading
    /// edge, past `width` for one that has scrolled off it entirely.
    private var hidden: CGFloat { scroll.x + overlap - leftOffset }

    /// Where the pinned header sits inside this block.
    static let leadingInset: CGFloat = 10

    /// Gap between the channel name and the time in the header.
    private let headerSpacing: CGFloat = 14

    /// How far *left* of a block the header is allowed to hang.
    private var headerFloor: CGFloat { -(channelNameWidth + headerSpacing) }

    /// Where the header sits inside this block.
    private var headerPin: CGFloat { max(hidden, headerFloor) }

    /// How far the programme title slides to stay clear of the logo column.
    private var slide: CGFloat {
        guard hidden > 0 else { return 0 }
        return min(hidden, max(0, width - 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: headerSpacing) {
                // Always present, never conditional. Its visibility is purely
                // geometric - `headerPin` slides it out past the block's leading
                // edge, and the block's clip does the hiding.
                Text(channel.displayName)
                    .fontWeight(.semibold)
                Text(program.startTime.clockLabel)
                //`airing` marks the block the
                // playhead is inside.
                if airing {
                    Circle()
                        .fill(Color(red: 0.886, green: 0.294, blue: 0.290))
                        .frame(width: 6, height: 6)
                }
            }
            .font(.system(size: metrics.guideSubtitleFont))
            .foregroundStyle(foreground.opacity(0.75))
            .lineLimit(1)
            .fixedSize()
            .offset(x: headerPin)
            // Above the title, so a long title sliding under the logo column
            // passes beneath the header rather than over it.
            .zIndex(1)

            // Sticky, like the header above it but clamped - it stays readable
            // as its block passes under the logo column instead of disappearing
            // with it.
            Text(program.displayTitle.isEmpty ? "Data not available" : program.displayTitle)
                .font(.system(size: metrics.guideTitleFont))
                .lineLimit(1)
                .truncationMode(.tail)
                .offset(x: slide)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Named, because `headerSpacing` is derived from it — see the note there.
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }

    /// sub_title if present, else an episode label, else the time range - always
    /// prefixed with the start time so a block reads standalone.
    private var subtitleLine: String {
        let start = program.startTime.clockLabel
        let subtitle = program.displaySubTitle
        if !subtitle.isEmpty { return "\(start) • \(subtitle)" }
        if let episode = program.episodeLabel { return "\(start) • \(episode)" }
        return "\(start) - \(program.endTime.clockLabel)"
    }
}

/// One pinned logo tile.
///
/// Adopts the logo's own plate colour when it has one, otherwise a stable
/// neutral - the same rule as the carousel cards.
struct GuideLogoTile: View {
    /// Gaps around the plate inside its row cell. Named because `TVGuideView`
    /// has to subtract exactly these to derive the column width - two literals
    /// that had to agree was how the tile and the column would drift apart.
    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 8
    
    var onChannelTap: (Channel) -> Void = { _ in }

    let channel: Channel
    let logoURL: URL?
    let palette: LogoPalette?
    let width: CGFloat
    let height: CGFloat

    @State private var plate: LogoPlate?
    @State private var isLogoHovered: Bool = false

    /// Only the fallback initial needs this - the tile's own width and height
    /// are handed down by `TVGuideView`, which has already resolved them.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var metrics: Metrics {
        .resolve(isRegularWidth: horizontalSizeClass == .regular)
    }

    /// The plate the artwork sits on: its own if it has one, a light neutral if
    /// it is a cut-out in dark ink, an ordinary dark neutral otherwise. See
    /// `logoTileColor(plate:seed:)`.
    private var background: RGBColor {
        logoTileColor(plate: plate, seed: channel.effectiveTvgID ?? channel.uuid)
    }

    private var plateWidth: CGFloat { width - Self.horizontalInset }
    private var plateHeight: CGFloat { height - Self.verticalInset }

    var body: some View {
        ZStack {
            background.color
            if let logoURL {
                AsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        // No button here — the whole tile is the button, wrapped
                        // by the logo column in `TVGuideView.grid`.
                        image.resizable().scaledToFit()
                    case .failure:
                        Image(systemName: "tv")
                            .foregroundStyle(background.foreground.opacity(0.6))
                    default:
                        Color.clear
                    }
                }
                .padding(6)
            } else {
                Text(channel.displayName.first.map(String.init) ?? "?")
                    .font(.system(size: metrics.guideLogoInitialFont, weight: .medium))
                    .foregroundStyle(background.foreground)
            }
        }
        
        // Same shape as a Continue Watching card, at guide scale — the plate is
        // wider than it is tall rather than square, and its corner radius scales
        // with it so the family resemblance holds at both sizes.
        .frame(width: plateWidth, height: plateHeight)
        .clipShape(
            RoundedRectangle(cornerRadius: guideLogoCornerRadius(forWidth: plateWidth),
                             style: .continuous)
        )
        // **After the clip, not before.** Scaling first and clipping second trims
        // the tile straight back to its unscaled bounds — and because the plate
        // is a `Color`, which fills whatever region it is given, that trim is
        // pixel-identical. Only the logo bitmap looked bigger, which read as the
        // artwork growing out of a plate that would not move. Below the clip, the
        // whole rounded plate scales as one object.
        .scaleEffect(isLogoHovered ? 1.05 : 1)
        .animation(.easeInOut(duration: 0.18), value: isLogoHovered)
        // The tile is the hover target, not the artwork inside it. A second
        // handler on the image reported `false` whenever the pointer crossed the
        // plate's 6pt margin while this one still said `true`, and the last one
        // to fire won — a flicker along the edge.
        //
        // **`onHover` is unavailable on tvOS**, not merely inert there: it fails
        // the build rather than compiling to nothing. A television has no
        // pointer, and the equivalent — focus — is already handled by
        // `guideBlockButtonStyle()` on the blocks beside this.
        #if !os(tvOS)
            .onHover { isLogoHovered = $0 }
        #endif
        .padding(.leading, 4)
        .padding(.trailing, Self.horizontalInset - 4)
        .padding(.vertical, Self.verticalInset / 2)
        // Cached per URL inside the actor, so this neither re-downloads nor
        // re-decodes when the tile scrolls back into view.
        .task(id: logoURL) {
            guard let logoURL, let palette else { return }
            plate = await palette.plate(for: logoURL)
        }
    }
}

import SwiftUI

/// A whole page for one category: its channels, and only its channels, in the
/// same guide grid the homepage uses.
///
/// The homepage guide is a *preview* — `maxRows` clips it to what fits the
/// viewport, because it sits under a carousel and a category grid and the page
/// has to end somewhere. This page is the guide, so it drops the row budget and
/// scrolls instead.
///
/// It takes the whole `HomeModel` rather than the four things it reads. The
/// model owns the one fetched catalog and the shared `LogoPalette`; handing over
/// slices would mean either passing five parameters or, worse, building a second
/// model — and a second model is a second full fetch of a large lineup.
struct CategoryView: View {
    let model: HomeModel
    let category: Category

    /// The channel whose player is open. Local to this page: pushing the player
    /// from here should return *here*, not to the homepage.
    @State private var playingChannel: Channel?

    /// The programme whose detail sheet is up — the selection itself, so it can
    /// bind straight to `.sheet(item:)`. See `GuideSelection`.
    @State private var programDetail: GuideSelection?

    /// The category the title menu has switched to, or nil for "still the one
    /// this page was opened with".
    ///
    /// **An id, and optional.** Seeding a `@State` with `category` would mean
    /// `State(initialValue:)`, which is re-evaluated on every rebuild and only
    /// the first result kept — the trap documented in the project notes. And
    /// storing a whole `Category` would freeze a snapshot of its channel list,
    /// so a pull-to-refresh that changed the group would not show through.
    @State private var switchedToID: Int?

    /// What the picker binds to: the switched-to id, falling back to the
    /// category this page was opened with.
    ///
    /// The write is wrapped in `withAnimation` rather than the guide carrying an
    /// `.animation(_:value:)`: the swap is one discrete user action, and driving
    /// it from the action means nothing else that happens to change `current` —
    /// a refresh landing, say — gets animated as though it were a switch.
    private var selection: Binding<Int> {
        Binding(
            get: { switchedToID ?? category.id },
            set: { newValue in
                withAnimation(.smooth(duration: 0.3)) { switchedToID = newValue }
            }
        )
    }

    /// The category actually on screen, resolved against the live catalog every
    /// time rather than held.
    private var current: Category {
        model.categories.first { $0.id == selection.wrappedValue } ?? category
    }

    /// Hard cap on rows, for the same reason the homepage has one: the grid
    /// builds every row and every block up front, so a 400-channel category
    /// would lay out thousands of blocks before drawing a pixel.
    ///
    /// Far higher than the homepage's budget, because here the guide is the
    /// point rather than a preview — and the overflow is stated below the grid
    /// rather than silently dropped.
    private static let maxRows = 100

    private var shownChannels: [Channel] {
        Array(current.channels.prefix(Self.maxRows))
    }

    private var hiddenCount: Int {
        max(0, current.channels.count - shownChannels.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // tvOS has no navigation bar to carry a title, so the page
                // carries its own. On iOS `.navigationTitle` already does it and
                // a second heading would just be a duplicate.
                #if os(tvOS)
                    header
                #endif

                TVGuideView(
                    channels: shownChannels,
                    guide: model.guide,
                    logoURLFor: model.catalog.logoURL(for:),
                    onLogoTap: { playingChannel = $0 },
                    onProgramTap: { programDetail = $0 },
                    palette: model.logoPalette
                )
                // Leading only, matching the homepage. The trailing margin is the
                // guide's own — it has to know where the lane ends to round it
                // off. See `TVGuideView.trailingInset`.
                .padding(.leading, Layout.isTV ? Layout.screenMarginH : 0)
                // **`.id` is what makes the transition possible at all.**
                //
                // Without it the grid keeps its identity across a switch and
                // SwiftUI diffs row by row — so rows whose channel happens to
                // appear in both categories stay put while the rest pop in and
                // out, which is the jarring part. Changing the id makes the swap
                // one removal and one insertion, and *that* is what a transition
                // can crossfade.
                //
                // It also resets the grid's internal state, which is wanted
                // here: the new lineup gets a fresh scroll-to-now instead of
                // inheriting the old category's horizontal offset.
                .id(current.id)
                .transition(.opacity)

                if hiddenCount > 0 {
                    Text("\(hiddenCount) more channels not shown.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .screenMargin()
                }
            }
            .padding(.vertical, Layout.screenMarginV + 16)
        }
        .refreshable { await model.load() }
        #if !os(tvOS)
            // Kept in step with the menu even though `.principal` replaces what
            // is drawn: this is what the *next* screen's back button is labelled
            // with, so a stale value would show up one push later.
            .navigationTitle(current.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    categoryMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Text(model.subtitle(for: current))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        // Rolls the digits rather than swapping the whole string,
                        // so the count reads as counting rather than blinking.
                            .contentTransition(.numericText())
                    }
                }
            }
        #endif
        // The player presents the same way it does from the homepage, and for
        // the same reason: a pushed destination on tvOS inherits the sidebar's
        // inset and offset, so it is never actually full screen.
        #if os(tvOS)
            .fullScreenCover(item: $playingChannel) { channel in
                player(for: channel)
            }
        #else
            .navigationDestination(item: $playingChannel) { channel in
                player(for: channel)
            }
        #endif
        .sheet(item: $programDetail) { selection in
            ProgramDetailView(
                selection: selection,
                logoURL: model.catalog.logoURL(for: selection.channel),
                palette: model.logoPalette,
                onPlay: { playingChannel = $0 }
            )
        }
    }

    #if !os(tvOS)
        /// The navigation title, as a menu: it names the category you are on and
        /// lists every other one to jump to.
        ///
        /// A `Picker` rather than a stack of `Button`s, because it checkmarks the
        /// current entry on its own.
        ///
        /// **`.inline` is load-bearing.** A `Picker` inside a `Menu` defaults to
        /// `.menu` style, which nests: the menu opens onto a single row showing
        /// the current category, and the names are a level further in. `.inline`
        /// drops the options straight into the parent menu, which is the whole
        /// point of putting them behind the title.
        private var categoryMenu: some View {
            Menu {
                Picker("Category", selection: selection) {
                    ForEach(model.categories) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Text(current.name)
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityLabel("Category, \(current.name)")
        }
    #endif

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(current.name)
                .font(.largeTitle.weight(.semibold))
            Text(model.subtitle(for: current))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .screenMargin()
    }

    private func player(for channel: Channel) -> some View {
        PlayerView(
            channel: channel,
            streamURL: model.client.streamURL(forChannelUUID: channel.uuid),
            programs: model.guide.programs(for: channel),
            logoURL: model.catalog.logoURL(for: channel),
            palette: model.logoPalette
        )
    }
}

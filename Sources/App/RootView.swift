import SwiftUI

/// The bottom navigation — `M3EToolbar.docked` with the four sections.
///
/// `TabView` handles the docked bar, safe-area insets, and (on tvOS) the top tab
/// strip and its focus behaviour, none of which had to be hand-positioned.
///
/// **tvOS gets two extra tabs.** Search is one of them because a pinned search
/// field is a focus trap on a TV: the remote catches it on every pass up or down
/// the page, which is what made the first TV build unusable. As a tab you enter
/// it deliberately, and `.searchable` brings the system keyboard with it.
/// Settings is the other, since the tab bar already does what the header's page
/// menu and gear did on the phone.
struct RootView: View {
    let client: DispatcharrClient

    /// Built in `.task`, not in an initialiser.
    ///
    /// A `View` is a struct SwiftUI rebuilds constantly, and
    /// `State(initialValue:)` evaluates its argument every time — it only keeps
    /// the first result. Constructing the model there would allocate a fresh one
    /// (and its repositories and logo cache) on every rebuild. `.task` runs once
    /// when the view appears.
    ///
    /// Owning it here rather than in `HomeView` also lets the tvOS Search tab
    /// share the same catalog and guide instead of fetching a second copy.
    @State private var model: HomeModel?

    /// Which sidebar entry is showing. Owned here so it survives the sidebar
    /// collapsing and expanding — and, on iPad, so rotating between a regular
    /// and a compact width does not reset it.
    @State private var sidebarSelection: SidebarDestination = .home

    /// Regular width gets the sidebar, compact keeps the tab bar.
    ///
    /// Width, not idiom: an iPad in Slide Over is compact and should behave like
    /// a phone. Asking "is this an iPad" would get that wrong. A native Mac is
    /// always regular and always takes the sidebar — see `RegularWidth`.
    @RegularWidth private var isRegularWidth

    /// The multiview session.
    ///
    /// Constructed inline rather than in `.task` — unlike the SwiftData
    /// container, an empty tile list opens nothing and holds nothing, so the
    /// throwaway instances SwiftUI builds on each rebuild cost nothing. It
    /// acquires players only when a tile is added.
    @State private var multiview = MultiviewModel()

    var body: some View {
        Group {
            if let model {
                // Tiles are drawn *over* the whole app, never inside a screen,
                // so browsing to the next channel leaves them playing.
                tabs(model: model)
                    .overlay { MultiviewOverlay(multiview: multiview) }
            } else {
                ProgressView("Loading channels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(multiview)
        .task {
            guard model == nil else { return }
            // Opened here rather than in an `init` or a `@State(initialValue:)`,
            // for the reason in CLAUDE.md: initial values are constructed on
            // every rebuild and thrown away, and this one opens a SQLite store.
            //
            // Not the SwiftUI `.modelContainer` scene modifier either — the
            // cache belongs to `ChannelRepository`, and `Sources/Data/` has no
            // SwiftUI imports to spend on it.
            let created = HomeModel(client: client, cache: CatalogCache.makeDefault())
            model = created
            await created.load()
        }
    }

    @ViewBuilder
    private func tabs(model: HomeModel) -> some View {
        #if os(tvOS)
            // A rail, not a tab strip — see `TVSidebarShell`.
            TVSidebarShell(selection: $sidebarSelection) { destination in
                screen(destination, model: model)
            }
        #else
            if isRegularWidth {
                // iPad and Mac: the same navigation set as tvOS, in a panel that
                // slides the content aside — see `SidebarShell`.
                SidebarShell(selection: $sidebarSelection) { destination in
                    screen(destination, model: model)
                }
            } else {
                TabView {
                    Tab("Home", systemImage: "house") {
                        HomeView(model: model)
                    }
                    Tab("Live TV", systemImage: "antenna.radiowaves.left.and.right") {
                        ComingSoonView(title: "Live TV")
                    }
                    Tab("Series", systemImage: "tv") {
                        ComingSoonView(title: "Series")
                    }
                    Tab("Movies", systemImage: "film") {
                        ComingSoonView(title: "Movies")
                    }
                }
            }
        #endif
    }

    /// The screen behind a sidebar entry.
    ///
    /// Shared by both shells. The stubs are the same honest ones the Flutter
    /// app's `() {}` menu entries get everywhere else.
    @ViewBuilder
    private func screen(_ destination: SidebarDestination, model: HomeModel) -> some View {
        switch destination {
        case .home:
            HomeView(model: model)
        case .search:
            #if os(tvOS)
                TVSearchTab(model: model)
            #else
                // iOS has no separate search screen: `HomeHeader`'s field
                // expands in place, so this entry just goes home.
                HomeView(model: model)
            #endif
        case .settings:
            SettingsView()
        case .favorites, .liveTV, .series, .movies, .recordings, .addPlaylist:
            ComingSoonView(title: destination.title)
        }
    }
}

#if os(tvOS)

    /// The tvOS search tab.
    ///
    /// Uses `.searchable` rather than the phone's custom glass header. On tvOS
    /// that presents the system search experience — a full-width field with the
    /// on-screen keyboard and remote dictation — which is both the expected
    /// pattern and considerably less to build than porting `HomeHeader`.
    ///
    /// `.searchScopes` renders the TV/Series/Movies chips as the system's own
    /// scope bar, so those come across too.
    struct TVSearchTab: View {
        @Bindable var model: HomeModel
        @State private var playingChannel: Channel?

        /// The multiview session, if tiles are up.
        @Environment(MultiviewModel.self) private var multiview

        /// One door for every channel tap on this screen.
        ///
        /// **Multiview changes what tapping a channel means**, and it has to change
        /// it everywhere at once — a carousel card, a guide block, a search result.
        /// Routing every site through here is what stops "add to the tiles" from
        /// working on some rows and opening full screen on others.
        private func open(_ channel: Channel) {
            guard multiview.isActive else {
                playingChannel = channel
                return
            }
            // Tiles are up, so the tap belongs to them whether or not there is room.
            // Falling through to full screen when the grid is full would replace the
            // multiview you are watching with a single stream, which is the opposite
            // of what the tap asked for.
            multiview.add(channel: channel, home: model)
        }

        var body: some View {
            NavigationStack {
                SearchResultsView(model: model) { open($0) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .searchable(text: $model.searchText, prompt: "Search")
                    .searchScopes($model.searchScope) {
                        ForEach(HomeModel.SearchScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    // Full screen for the same reason as `HomeView`: a push
                    // would stay inside the sidebar shell's inset content area.
                    .fullScreenCover(item: $playingChannel) { channel in
                        PlayerView(
                            channel: channel,
                            streamURL: model.client.streamURL(forChannelUUID: channel.uuid),
                            programs: model.guide.programs(for: channel),
                            logoURL: model.catalog.logoURL(for: channel),
                            palette: model.logoPalette
                        )
                    }
            }
        }
    }

#endif

/// Honest stub for the tabs the Flutter app also leaves as `() {}`.
struct ComingSoonView: View {
    let title: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                title,
                systemImage: "hammer",
                description: Text("Not built yet.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
        }
    }
}

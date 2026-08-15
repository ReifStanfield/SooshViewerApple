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

    #if os(iOS)
        /// Regular width gets the sidebar, compact keeps the tab bar.
        ///
        /// Width, not idiom: an iPad in Slide Over is compact and should behave
        /// like a phone, and a resized Mac window is the same story. Asking
        /// "is this an iPad" would get both wrong.
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        Group {
            if let model {
                tabs(model: model)
            } else {
                ProgressView("Loading channels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard model == nil else { return }
            let created = HomeModel(client: client)
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
            if horizontalSizeClass == .regular {
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

        var body: some View {
            NavigationStack {
                SearchResultsView(model: model) { playingChannel = $0 }
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

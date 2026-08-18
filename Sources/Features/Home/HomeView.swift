import SwiftUI

/// The homepage: Continue Watching carousel over a channel/guide list.
///
/// Structural differences from `MyHomePage`, all deliberate:
///
/// * No `Stack` with a `Positioned` header and a `Positioned` toolbar. The
///   header comes from `NavigationStack` + `.toolbar`, and the bottom bar from
///   `TabView` in `RootView` — both of which handle safe-area insets, so the
///   `_toolbarClearance = 88` fudge disappears.
/// * No `_playerOpen` bool. Navigation is state-driven: `navigationDestination`
///   fires once per value, so a double tap cannot push two players.
/// * The header is a pinned `safeAreaInset`, so the page menu, settings button
///   and search field all stay on screen while the content scrolls under them.
struct HomeView: View {
    @Bindable var model: HomeModel

    /// The channel whose player is open, or nil. This *is* the navigation state.
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


    /// The category whose page is open, or nil. Same pattern: state-driven, so a
    /// double tap cannot push two copies of the page.
    @State private var openCategory: Category?

    /// The scrolling page's size, used to budget guide rows.
    @State private var viewport: CGSize = .zero

    /// Whether the header is in its expanded search state.
    @State private var isSearching = false

    /// Whether the settings sheet is up.
    @State private var showingSettings = false
    
    /// The programme whose detail sheet is up, or nil.
    ///
    /// The selection *is* the presentation state — bound straight to
    /// `.sheet(item:)`. A `Bool` plus a separate "which programme" is two
    /// sources of truth for one fact, and with a `Bool` the sheet also reads
    /// whatever the other property held when the sheet was built, which is a
    /// stale value on the first tap.
    @State private var programDetail: GuideSelection?

    /// Cards, tiles and guide rows all step up at regular width — see `Metrics`.
    @RegularWidth private var isRegularWidth

    private var metrics: Metrics {
        .resolve(isRegularWidth: isRegularWidth)
    }

    #if os(tvOS)
        /// Focus scope for the page, so a default focus target can be named.
        @Namespace private var contentFocus
    #endif

    var body: some View {
        NavigationStack {
            content
                // **Inside the stack on iOS, and *only* on iOS.**
                //
                // On iOS a `NavigationStack` paints the opaque system background
                // over anything behind it, so a backdrop applied outside it is
                // invisible — the same trap the project notes record for
                // `TabView`. Applied to the stack's own content, it sits above
                // that system fill.
                //
                // **On tvOS `TVSidebarShell` already draws it, and drawing it
                // again here is what made the rail look like it had a
                // background of its own.** `AppBackground` is a horizontal ramp
                // across *its own frame*: the shell's spans the whole screen,
                // while this one spans only the content, which is inset past the
                // rail. Two ramps with different origins meet at the rail's edge
                // and the seam reads as a separate sidebar backdrop. One
                // backdrop, full width, behind everything.
                #if !os(tvOS)
                    .appBackground()
                #endif
                #if !os(tvOS)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HomeHeader(
                            searchText: $model.searchText,
                            scope: $model.searchScope,
                            isSearching: $isSearching,
                            onNowOnly: $model.onNowOnly,
                            onSettings: { showingSettings = true }
                        )
                    }
                    .sheet(isPresented: $showingSettings) {
                        // `.sheet` adapts on its own — full height on a phone, a
                        // centred form sheet on a regular-width window — so there
                        // is no equivalent of Flutter's `showAppSheet()` size
                        // branch.
                        SettingsView()
                    }
                    // The screen draws its own header, so the system bar would be
                    // a second one. `.navigationBar` is a UIKit placement and is
                    // unavailable on macOS, where a `NavigationStack` puts its
                    // chrome in the window toolbar instead — see the
                    // `.toolbar(.hidden)` on the Mac window in `SooshViewerApp`.
                    #if os(iOS)
                        .toolbar(.hidden, for: .navigationBar)
                    #endif
                #endif
                // **`fullScreenCover` on tvOS, a push on iOS.**
                //
                // The tvOS shell insets its content by the collapsed sidebar
                // rail and slides it sideways when the rail expands. A pushed
                // destination inherits both, so the player was never actually
                // full screen — it sat 120pt in from the left and shifted
                // whenever focus touched the sidebar. A full-screen cover is
                // presented above the shell, so it owns the whole panel.
                #if os(tvOS)
                    .fullScreenCover(item: $playingChannel) { channel in
                        PlayerView(
                            channel: channel,
                            streamURL: model.client.streamURL(forChannelUUID: channel.uuid),
                            programs: model.guide.programs(for: channel),
                            logoURL: model.catalog.logoURL(for: channel),
                            palette: model.logoPalette
                        )
                    }
                #else
                    .navigationDestination(item: $playingChannel) { channel in
                        PlayerView(
                            channel: channel,
                            streamURL: model.client.streamURL(forChannelUUID: channel.uuid),
                            programs: model.guide.programs(for: channel),
                            logoURL: model.catalog.logoURL(for: channel),
                            palette: model.logoPalette
                        )
                    }
                #endif
                // A push on **both** platforms, unlike the player. The player
                // needs the whole panel, which is why tvOS covers the shell; a
                // category page is ordinary content and should keep the sidebar
                // — and its own back-to-home affordance with it.
                .navigationDestination(item: $openCategory) { category in
                    CategoryView(model: model, category: category)
                }
                // A sheet rather than a push: the details are a look at
                // something, not a place you navigate to, and you come straight
                // back to the same spot in the guide.
                .sheet(item: $programDetail) { selection in
                    ProgramDetailView(
                        selection: selection,
                        logoURL: model.catalog.logoURL(for: selection.channel),
                        palette: model.logoPalette,
                        onPlay: { open($0) }
                    )
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Loading channels…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("Can't load channels", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent)
            }

        case .loaded:
            loadedContent
        }
    }

    private var loadedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                if isSearching {
                    // Search replaces the page rather than filtering it: the
                    // scope chips choose *what kind of thing* you are looking
                    // for, so a narrowed carousel-and-guide would not answer the
                    // question being asked.
                    SearchResultsView(model: model) { open($0) }
                } else {
                    continueWatching
                    // **No categories on tvOS.** The grid is a browsing aid for
                    // a pointer, and on a remote it is a wall of focus targets
                    // between the carousel and the guide — every trip down the
                    // page pays for it. The sidebar already carries the same
                    // navigation, so on TV the home page is what is on now and
                    // what is on next.
                    guideGrid
                    
                    #if !os(tvOS)
                        categoriesGrid
                    #endif
                }
            }
            .padding(.vertical, Layout.screenMarginV + 16)
            #if os(tvOS)
                .focusScope(contentFocus)
            #endif
        }
        // The page's own size, so the guide's row budget can be derived from it
        // without a nested `GeometryReader` — see `guideRowBudget`.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        // Content scrolls *under* the pinned header, which means it also reaches
        // the status-bar strip above it. `.hard` is iOS 26's scroll edge effect:
        // it fades content out where it meets the pinned bar instead of letting
        // it bleed past. Without it, headings visibly ride up over the clock.
        #if !os(tvOS)
            .scrollEdgeEffectStyle(.automatic, for: .top)
        #endif
        .refreshable { await model.load() }
    }

    private var continueWatching: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Watching")
                .font(Layout.isTV ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(.gray)
                .screenMargin()

           
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Layout.isTV ? 40 : 16) {
                    ForEach(model.carouselChannels) { channel in
                        Button {
                            open(channel)
                        } label: {
                            ChannelCard(
                                channel: channel,
                                logoURL: model.catalog.logoURL(for: channel),
                                subtitle: model.subtitle(for: channel),
                                isLive: model.currentProgram(for: channel)?.isLive ?? false,
                                palette: model.logoPalette
                            )
                        }
                        // The hover lift and its plate come from
                        // `cardButtonStyle()` now, so the whole card — artwork
                        // and both lines of text — moves as one.
                        .cardButtonStyle()
                        #if os(tvOS)
                            // Start focus on the first card rather than in the
                            // tab bar, so the remote is already in content.
                            .prefersDefaultFocus(
                                channel.id == model.carouselChannels.first?.id,
                                in: contentFocus
                            )
                        #endif
                    }
                }
                // The Flutter carousel builds every card up front. LazyHStack
                // builds only what is on screen, so the 20-item cap is a product
                // decision here rather than a performance one.
                .scrollTargetLayout()
                // Room for a focused card to grow into. A scaled card is drawn
                // outside its layout bounds, so without this the lift is cropped
                // top and bottom by the row's own height.
                .padding(.vertical, Layout.isTV ? 40 : 0)
            }
            .contentMargins(.horizontal, Layout.screenMarginH, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            // A scroll view clips its content by default, which would shave the
            // lifted card off at the viewport edge.
            .scrollClipDisabled()
            // The carousel is one focus group, so the remote runs along it
            // before jumping to the guide below.
            .tvFocusSection()
        }
    }

    /// The real 2D guide grid, replacing the interim per-channel list.
    ///
    /// `maxRows` comes from the viewport the way `guideRowCount` does in
    /// Flutter: a window-size-class limit and a ~60% height cap, whichever is
    /// tighter. The grid is not virtualised, so this bounds its work as well as
    /// its height.
    private var guideGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TV Guide")
                .font(Layout.isTV ? .title2.weight(.semibold) : .title3.weight(.semibold)
                ).foregroundStyle(.gray)
                .screenMargin()

            if model.guideChannels.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
                    .frame(height: 200)
            } else {
                // No `GeometryReader` and no explicit height: `TVGuideView`
                // already sizes itself to `rows × rowHeight`.
                //
                // The earlier version wrapped it in a `GeometryReader` and set a
                // separate height, which meant the row budget and the reserved
                // height were two independent expressions that had to agree —
                // and they didn't. The guide drew 4 rows inside an 800pt box and
                // the page scrolled into a wall of empty black. Letting the child
                // size itself removes the chance to disagree.
                TVGuideView(
                    channels: model.guideChannels,
                    guide: model.guide,
                    logoURLFor: model.catalog.logoURL(for:),
                    onLogoTap: { open($0) },
                    onProgramTap: { programDetail = $0 },
                    palette: model.logoPalette,
                    maxRows: guideRowBudget
                )
                // Leading margin only *here*; the trailing one belongs to the
                // guide, which needs to know where its lane ends in order to
                // round it off — see `TVGuideView.trailingInset`.
                //
                // The lane used to run off the right edge of the screen on
                // purpose, so a programme continuing past the viewport read as
                // continuing. The rounded end says the same thing without the
                // bars appearing to bleed out of the app.
                .padding(.leading, Layout.isTV ? Layout.screenMarginH : 0)
            }
        }
    }
    /// The category grid: one card per channel group that has channels in it.
    ///
    /// `LazyVGrid` with `.adaptive`, not a `Grid` with hand-built `GridRow`s.
    /// `Grid` needs the row split decided up front, which means recomputing it
    /// for every width the app runs at; `.adaptive` fits as many columns as the
    /// page has room for and reflows on rotation for free.
    ///
    /// A card pushes `CategoryView` — a full page holding a guide of just that
    /// category's channels.
    @ViewBuilder
    private var categoriesGrid: some View {
        if !model.categories.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Categories")
                    .font(Layout.isTV ? .title2.weight(.semibold) : .title3.weight(.semibold))
                    .foregroundStyle(.gray)
                    .screenMargin()

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: metrics.categoryCardMinWidth),
                                       spacing: Layout.isTV ? 40 : 8)],
                    spacing: Layout.isTV ? 40 : 8
                ) {
                    ForEach(model.categories) { category in
                        Button {
                            openCategory = category
                        } label: {
                            CategoryCard(
                                category: category,
                                subtitle: model.subtitle(for: category)
                            )
                        }
                        .cardButtonStyle()
                    }
                }
                .screenMargin()
                .tvFocusSection()
            }
        }
    }

    /// Rows drawn in the guide, hard cap.
    ///
    /// The grid builds every row and block up front, so the lineup is capped
    /// rather than handing it hundreds of channels.
    private let maxGuideRows = 40

    /// How many rows the guide should draw for the current page size.
    private var guideRowBudget: Int {
        // The same row height the guide will actually draw with. Budgeting
        // against a different one is how the guide once drew four rows inside an
        // 800pt box.
        let byViewport = guideRowCount(viewport: viewport, rowHeight: metrics.guideRowHeight)
        return max(1, min(byViewport, maxGuideRows))
    }
}

#Preview {
    let model = HomeModel.preview
    
    HomeView(model: model)
        // Simulate what RootView does to kick off the network request
        .task {
            await model.load()
        }
}

extension HomeModel {
    @MainActor
    static var preview: HomeModel {
        // 1. Define how the mock network should respond
        MockURLProtocol.requestHandler = { request in
            let urlString = request.url?.absoluteString ?? ""
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            
            // 2. Return dummy JSON based on the endpoint being called.
            // Note: Update the path strings here to match whatever paths
            // `ChannelRepository` and `EPGRepository` actually request.
            // Groups first: its path also contains "/channels", so the broader
            // check below would swallow it.
            if urlString.contains("/channels/groups") {
                // A bare array, which is what this endpoint really returns —
                // and `channel_count` as a string, which it also really does.
                let mockGroupsJSON = """
                [
                    {"id": 1, "name": "US | Sports HD", "channel_count": "2"},
                    {"id": 2, "name": "News", "channel_count": "1"}
                ]
                """
                return (response, mockGroupsJSON.data(using: .utf8)!)
            } else if urlString.contains("/channels/channels") {
                // Mock paginated or enveloped channels response
                let mockChannelsJSON = """
                {
                    "results": [
                        {"id": 1, "uuid": "a", "name": "ESPN",
                         "channel_number": 206, "channel_group_id": 1},
                        {"id": 2, "uuid": "b", "name": "TNT",
                         "channel_number": 245, "channel_group_id": 1},
                        {"id": 3, "uuid": "c", "name": "CNN",
                         "channel_number": 202, "channel_group_id": 2}
                    ]
                }
                """
                return (response, mockChannelsJSON.data(using: .utf8)!)
            } else if urlString.contains("/channels") {
                // Logos, and anything else under /channels.
                return (response, #"{"results": []}"#.data(using: .utf8)!)
            } else if urlString.contains("/epg/grid") {
                // Mock enveloped EPG response
                let mockGuideJSON = """
                {
                    "data": []
                }
                """
                return (response, mockGuideJSON.data(using: .utf8)!)
            }
            
            // Fallback empty response
            return (response, Data())
        }
        
        // 3. Create a custom URLSession using the mock protocol
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        // 4. Bypass authentication requirements for the preview
        let inMemoryTokens = InMemoryTokenStore()
        Task {
            await inMemoryTokens.save(access: "preview-access", refresh: "preview-refresh")
        }

        // 5. Initialize the client with the intercepted session and pre-loaded tokens
        let mockClient = DispatcharrClient(
            baseURL: "https://mock.preview.local",
            tokens: inMemoryTokens,
            session: mockSession
        )

        return HomeModel(client: mockClient)
    }
}

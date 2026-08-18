import SwiftUI

// Excluded on tvOS rather than limited to iOS. The TV has `TVSidebarShell`, a
// genuinely different piece of chrome for a ten-foot device; everything else —
// iPad at regular width, and now a native Mac window, which is always regular —
// wants this one. Nothing inside is UIKit-only.
#if !os(tvOS)

    /// Sizes for the iPad/Mac sidebar.
    ///
    /// Much smaller than `TVSidebarShell`'s: that one is a ten-foot device, where
    /// a 420pt panel and 24pt type are read from across a room. These are the
    /// pointer-and-touch equivalents.
    private enum SidebarMetrics {
        /// Width when open, sized for the longest label.
        static let open: CGFloat = 300
        static let rowHeight: CGFloat = 50
        static let iconSize: CGFloat = 30

        /// Margin around the floating panel, on all four sides.
        ///
        /// The panel no longer runs edge to edge: rounded corners against the
        /// screen edge read as a rendering error, so it is inset far enough for
        /// the corners to be corners.
        static let inset: CGFloat = 8

        /// Corner radius of the panel.
        static let cornerRadius: CGFloat = 28

        /// How far the content slides when the panel opens.
        ///
        /// The panel's *full* footprint, margins included, so content clears it
        /// rather than sliding underneath its trailing edge. The closed state
        /// leaves no gutter, so content still runs edge to edge and the guide
        /// gets the whole screen.
        static var slide: CGFloat { open + inset * 2 }

        /// Width of the leading strip that opens the panel by dragging.
        ///
        /// Deliberately narrow. It sits over the guide's pinned logo column and
        /// the first few points of the Continue Watching carousel, so any wider
        /// and it would start eating horizontal scrolls that were meant for the
        /// content underneath.
        static let edgeGrabber: CGFloat = 16
    }

    /// The iPad/Mac navigation shell: a panel down the leading edge, opened by a
    /// button in the gutter and closed by one in the panel's own top-right.
    ///
    /// **Replaces `TabView` at regular width.** The panel covers everything the
    /// tab bar did plus the entries a four-tab bar has no room for — Favorites,
    /// the playlist group, Recordings, Settings. `RootView` keeps the tab bar at
    /// compact width, where a 300pt panel would cover most of the screen.
    ///
    /// **The content is laid out once and then offset**, exactly as on tvOS: it
    /// gets a permanent leading margin of `gutter`, and opening the panel slides
    /// it right by a render transform. Re-laying-out on every toggle would push
    /// the guide grid — hundreds of absolutely-positioned blocks — through a full
    /// layout pass mid-animation.
    ///
    /// **Toggle-driven, not focus-driven.** The tvOS rail opens when the remote
    /// lands in it, because focus is unambiguous there. A pointer has no such
    /// signal, so this is an explicit open/close — which is what the mockup shows.
    struct SidebarShell<Content: View>: View {
        @Binding var selection: SidebarDestination
        @ViewBuilder let content: (SidebarDestination) -> Content

        @State private var isOpen = false
        @State private var playlistExpanded = true

        var body: some View {
            ZStack(alignment: .leading) {
                content(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Screens draw their own way in — on Home that is the button
                    // in `HomeHeader`, which is why no button lives here.
                    //
                    // Rebuilt on every body evaluation, so `isOpen` inside it is
                    // always current. A value captured once at init would tell
                    // the header the panel was shut forever.
                    .environment(
                        \.sidebar,
                        SidebarControl(isOpen: isOpen, open: { isOpen = true })
                    )
                    .offset(x: isOpen ? SidebarMetrics.slide : 0)
                    // **No scrim, and no tap-to-dismiss.** The panel is a
                    // persistent piece of navigation rather than a modal: the
                    // content beside it stays live and fully interactive while it
                    // is open, and the two buttons are what open and close it.
                    // Dimming would say the opposite — that the content is
                    // suspended behind a sheet you have to get rid of first.
                    //
                    // The escape hatch. Only Home draws an open button, so
                    // without this a destination like Settings would have no way
                    // back to the sidebar at all.
                    .overlay(alignment: .leading) {
                        if !isOpen {
                            edgeGrabber
                        }
                    }

                panel
            }
            .animation(.snappy(duration: 0.28), value: isOpen)
            .animation(.snappy(duration: 0.28), value: playlistExpanded)
            // **A flat fill, not `appBackground()`.**
            //
            // The shell used to draw the full backdrop here, which meant the
            // animated shader ran twice: once here and once inside `HomeView`.
            // Only the inner one is ever seen — a `NavigationStack` paints the
            // opaque system background over whatever is behind it, which is why
            // the backdrop has to be applied to the stack's *content* in the
            // first place. Verified by deleting the inner one and watching the
            // whole page go flat.
            //
            // Something still has to sit behind the panel: it is glass, so it
            // refracts what is under it, and the 8pt gutters around it are not
            // covered by the content once it slides. That is what this is — the
            // backdrop's own edge colour, so the gutters match the darkest part
            // of the page rather than showing the window through them.
            .background(AppBackground.edge.color.ignoresSafeArea())
        }

        /// An invisible strip down the leading edge that opens the panel when
        /// dragged right — the standard iPad gesture, and the only way into the
        /// sidebar from a screen that has no header of its own.
        private var edgeGrabber: some View {
            Color.clear
                .frame(width: SidebarMetrics.edgeGrabber)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { value in
                            if value.translation.width > 24 { isOpen = true }
                        }
                )
                .accessibilityHidden(true)
        }

        private var panel: some View {
            VStack(alignment: .leading, spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        // No Search row, unlike tvOS. There a pinned field is a
                        // focus trap so search has to be its own screen; here
                        // `HomeHeader`'s field expands in place, and a row that
                        // just went home would be a dead end.
                        group([.home])
                        Spacer().frame(height: 20)
                        playlistGroup
                        Spacer().frame(height: 20)
                        group([.recordings, .settings, .addPlaylist])
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
            }
            .frame(width: SidebarMetrics.open)
            .frame(maxHeight: .infinity, alignment: .top)
            // **Glass, tinted grey — not an opaque fill under a material.**
            //
            // The previous `.background(.black.opacity(0.9))` plus
            // `.ultraThinMaterial` was two layers fighting: the near-opaque black
            // sat on top and left the material with almost nothing to show
            // through, so it read as flat charcoal. `.tint` is how Liquid Glass
            // takes a colour — the grey goes *into* the material rather than over
            // it, so the panel still refracts the content sliding past behind it.
            .glassEffect(
                .regular.tint(.white.opacity(0.14)),
                in: RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius,
                                     style: .continuous)
            )
            // Floats clear of all four screen edges. Without this the rounded
            // corners would be cut off by the screen on the leading side.
            .padding(SidebarMetrics.inset)
            // Offscreen when closed rather than hidden: the panel keeps its
            // identity across the toggle, so the rows are not rebuilt and the
            // slide has something continuous to animate. Its own margins are
            // part of what has to clear the edge, hence `slide` rather than
            // `open`.
            .offset(x: isOpen ? 0 : -SidebarMetrics.slide)
        }

        /// Wordmark left, close button right — the arrangement in the mockup.
        private var header: some View {
            HStack {
                Text("SOOSH")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    isOpen = false
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close sidebar")
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }

        private func group(_ destinations: [SidebarDestination]) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(destinations, id: \.self) { destination in
                    row(destination)
                }
            }
        }

        /// The playlist header and, when open, its channels. The header is not a
        /// destination — tapping it expands its children instead of navigating.
        private var playlistGroup: some View {
            VStack(alignment: .leading, spacing: 6) {
                row(.favorites)

                SidebarRow(
                    title: "Dispatcharr",
                    symbol: "link",
                    tint: Color(red: 0.914, green: 0.118, blue: 0.388),
                    isSelected: false,
                    accessory: playlistExpanded ? .chevronDown : .chevronRight
                ) {
                    playlistExpanded.toggle()
                }

                if playlistExpanded {
                    ForEach([SidebarDestination.liveTV, .series, .movies], id: \.self) { child in
                        row(child, isChild: true)
                    }
                }
            }
        }

        private func row(_ destination: SidebarDestination, isChild: Bool = false) -> some View {
            SidebarRow(
                title: destination.title,
                symbol: destination.symbol,
                tint: nil,
                isSelected: selection == destination,
                accessory: destination == .favorites ? .chevronRight : .none,
                isChild: isChild
            ) {
                selection = destination
                // Choosing a destination dismisses the panel. It overlays the
                // content, so leaving it up would hide the screen just chosen.
                isOpen = false
            }
        }
    }

    /// One row in the panel.
    ///
    /// Its own type rather than `TVSidebar`'s `SidebarRowView`: that one is
    /// built around `isFocused` and the rail's collapsed/expanded width, neither
    /// of which exists here. Only `SidebarDestination` is genuinely shared.
    private struct SidebarRow: View {
        enum Accessory { case none, chevronRight, chevronDown }

        let title: String
        let symbol: String
        var tint: Color?
        let isSelected: Bool
        var accessory: Accessory = .none
        var isChild: Bool = false
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 14) {
                    icon
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    accessoryIcon
                }
                .padding(.horizontal, 12)
                .frame(height: SidebarMetrics.rowHeight)
                .foregroundStyle(isSelected ? Color.black : .white)
                .background(
                    isSelected ? Color.white : .white.opacity(0.001),
                    in: Capsule()
                )
                .opacity(isChild && !isSelected ? 0.65 : 1)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.leading, isChild ? 20 : 0)
        }

        @ViewBuilder
        private var icon: some View {
            if let tint {
                Image(systemName: symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
                    .background(tint, in: Circle())
            } else {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
            }
        }

        @ViewBuilder
        private var accessoryIcon: some View {
            switch accessory {
            case .none: EmptyView()
            case .chevronRight: Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
            case .chevronDown: Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
            }
        }
    }

#endif

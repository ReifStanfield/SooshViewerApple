import SwiftUI

#if os(tvOS)

    // `SidebarDestination` is shared with the iPad/Mac shell — see
    // `SidebarDestination.swift`.

    /// A focusable row identity. The playlist header is focusable but is not a
    /// destination — selecting it expands its children instead of navigating.
    private enum SidebarRow: Hashable {
        case destination(SidebarDestination)
        case playlistHeader
    }

    /// Sizes for the rail.
    private enum SidebarMetrics {
        /// Width when collapsed: wide enough for the icon badge and its padding.
        static let collapsed: CGFloat = 120
        /// Width when expanded, sized for the longest label.
        static let expanded: CGFloat = 420
        static let rowHeight: CGFloat = 76
        static let iconSize: CGFloat = 44
    }

    /// The tvOS navigation shell: an icon rail down the leading edge that opens
    /// into a labelled sidebar when it takes focus.
    ///
    /// **Replaces `TabView` on tvOS.** A top tab strip costs a whole row of
    /// vertical space on a 1080-tall screen and puts navigation in the path of
    /// every upward focus move; a rail sits out of the way and is only reached
    /// deliberately by pressing left.
    ///
    /// **Expansion is driven by focus, not by a tap.** `@FocusState` on the rows
    /// means the sidebar opens the moment the remote lands anywhere in it and
    /// closes as soon as focus returns to content — no toggle to get out of sync
    /// with where the user actually is.
    ///
    /// The rail **overlays** the content rather than pushing it: the content is
    /// laid out once with a leading inset of `collapsed`, and expanding floats
    /// the labels over it. Pushing would re-lay-out the whole page — including
    /// the guide grid — on every focus change.
/// The tvOS navigation shell: an icon rail down the leading edge that opens
    /// into a labelled sidebar when it takes focus.
    ///
    /// **Replaces `TabView` on tvOS.** A top tab strip costs a whole row of
    /// vertical space on a 1080-tall screen and puts navigation in the path of
    /// every upward focus move; a rail sits out of the way and is only reached
    /// deliberately by pressing left.
    ///
    /// **Expansion is driven by focus, not by a tap.** `@FocusState` on the rows
    /// means the sidebar opens the moment the remote lands anywhere in it and
    /// closes as soon as focus returns to content — no toggle to get out of sync
    /// with where the user actually is.
    ///
    /// **Layout:** The rail and content sit side-by-side. Expanding the rail
    /// pushes the content to the right.
struct TVSidebarShell<Content: View>: View {
        @Binding var selection: SidebarDestination
        @ViewBuilder let content: (SidebarDestination) -> Content

        @FocusState private var focusedRow: SidebarRow?
        @State private var playlistExpanded = true

        private var isExpanded: Bool { focusedRow != nil }

        var body: some View {
            ZStack(alignment: .leading) {
                
                // 1. CONTENT LAYER
                content(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Give it a permanent leading margin so it doesn't sit under the collapsed rail
                    .padding(.leading, SidebarMetrics.collapsed)
                    // Visually slide it to the right when the sidebar opens, bypassing layout recalculation
                    .offset(x: isExpanded ? (SidebarMetrics.expanded - SidebarMetrics.collapsed) : 0)
                    .ignoresSafeArea()
                
                // 2. SIDEBAR LAYER
                rail
            }
            // 3. Apply your smoothstep gradient to the root container
            .appBackground()
            .animation(.snappy(duration: 0.28), value: isExpanded)
            .animation(.snappy(duration: 0.28), value: playlistExpanded)
        }

        private var rail: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    group([.home, .search])
                    Spacer().frame(height: 28)
                    playlistGroup
                    Spacer().frame(height: 28)
                    group([.recordings, .settings, .addPlaylist])
                }
                .padding(.vertical, 40)
                .padding(.horizontal, 20)
            }
            .scrollClipDisabled()
            .frame(width: isExpanded ? SidebarMetrics.expanded : SidebarMetrics.collapsed)
            .focusSection()
        }


        private func group(_ destinations: [SidebarDestination]) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(destinations, id: \.self) { destination in
                    row(destination)
                }
            }
        }

        /// The playlist header and, when open, its channels.
        private var playlistGroup: some View {
            VStack(alignment: .leading, spacing: 10) {
                row(.favorites)

                SidebarRowView(
                    title: "Dispatcharr",
                    symbol: "link",
                    tint: Color(red: 0.914, green: 0.118, blue: 0.388),
                    isSelected: false,
                    isExpanded: isExpanded,
                    accessory: playlistExpanded ? .chevronDown : .chevronRight,
                    isFocused: focusedRow == .playlistHeader
                ) {
                    playlistExpanded.toggle()
                }
                .focused($focusedRow, equals: .playlistHeader)

                if playlistExpanded {
                    ForEach([SidebarDestination.liveTV, .series, .movies], id: \.self) { child in
                        row(child, isChild: true)
                    }
                }
            }
        }

        private func row(_ destination: SidebarDestination, isChild: Bool = false) -> some View {
            SidebarRowView(
                title: destination.title,
                symbol: destination.symbol,
                tint: nil,
                isSelected: selection == destination,
                isExpanded: isExpanded,
                accessory: destination == .favorites ? .chevronRight : .none,
                isChild: isChild,
                isFocused: focusedRow == .destination(destination)
            ) {
                selection = destination
            }
            .focused($focusedRow, equals: .destination(destination))
        }
    }

    /// One pill in the rail.
    private struct SidebarRowView: View {
        enum Accessory { case none, chevronRight, chevronDown }

        let title: String
        let symbol: String
        var tint: Color?
        let isSelected: Bool
        let isExpanded: Bool
        var accessory: Accessory = .none
        var isChild: Bool = false
        let isFocused: Bool
        let action: () -> Void


        var body: some View {
            Button(action: action) {
                HStack(spacing: 16) {
                    icon
                    if isExpanded {
                        Text(title)
                            .font(.title2.weight(.bold)
                                .pointSize(24))
                            .lineLimit(1)
                            // Collapsing animates the width; without this the
                            // label wraps to two lines on the way through.
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        accessoryIcon
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: SidebarMetrics.rowHeight)
                .frame(
                    width: isExpanded
                        ? SidebarMetrics.expanded - 40
                        : SidebarMetrics.collapsed - 40,
                    alignment: .leading
                )
                .foregroundStyle(foreground)
                .background(background, in: Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
                .opacity(isChild && !isSelected ? 0.55 : 1)
            }
            .buttonStyle(SidebarButtonStyle())
            .padding(.leading, isChild && isExpanded ? 24 : 0)
        }

        @ViewBuilder
        private var icon: some View {
            if let tint {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold)
                        .pointSize(24))
                    .foregroundStyle(.white)
                    .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
                    .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold)
                        .pointSize(24))
                    .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
            }
        }

        @ViewBuilder
        private var accessoryIcon: some View {
            switch accessory {
            case .none: EmptyView()
            case .chevronRight: Image(systemName: "chevron.right").font(.body.weight(.semibold))
            case .chevronDown: Image(systemName: "chevron.down").font(.body.weight(.semibold))
            }
        }

        /// Selected is a filled white pill with dark content; focus is a lighter
        /// fill. Selection has to survive losing focus, so the two are separate
        /// states rather than one.
        private var background: Color {
            if isSelected { return .white }
            if isFocused { return Color(white: 0.32) }
            return Color(white: 0.16)
        }

        private var foreground: Color {
            isSelected ? .black : .white
        }
    }

    /// No lift, no plate — the pill's own fill is the focus indicator, so the
    /// only job here is to keep the label from being restyled by `.card`.
    private struct SidebarButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

#endif

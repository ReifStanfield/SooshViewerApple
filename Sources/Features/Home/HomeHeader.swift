import SwiftUI

/// The pinned top of the homepage: page menu, settings, and search.
///
/// Replaces `.navigationTitle` + `.searchable`. Both of those *scroll* — a large
/// title collapses into the bar and the system search field slides away — and
/// the design calls for all three controls staying put, which is what
/// `safeAreaInset(edge: .top)` in `HomeView` provides.
///
/// It has two states, the way `.searchable` does: at rest it shows the page menu
/// and settings above the field; once the field takes focus those give way to a
/// close button beside the field and a row of scope chips beneath it.
struct HomeHeader: View {
    @Binding var searchText: String
    @Binding var scope: HomeModel.SearchScope
    @Binding var isSearching: Bool
    @Binding var onNowOnly: Bool
    let onSettings: () -> Void

    @FocusState private var searchFocused: Bool

    @Environment(\.sidebar) private var sidebar
    @RegularWidth private var isRegularWidth
    @State private var blurRadius: CGFloat = 0
    var body: some View {
        // One container for the whole header so the pills share a backdrop and
        // blend if they come close, rather than each sampling independently.
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 12) {
                if !isSearching {
                    HStack(spacing: 12) {
                        // Present only when a sidebar exists, and only while it
                        // is shut.
                        if let sidebar, !sidebar.isOpen {
                            sidebarButton(action: sidebar.open)
                                .transition(.scale.combined(with: .opacity))
                        }
                        if !isRegularWidth {
                            pageMenu
                        } else {
                            Text("Home")
                                .font(.system(size: 40).bold())
                                .phaseAnimator([0.0, 1.0, 0.0], trigger: sidebar?.isOpen) { content, phase in
                                    content.blur(radius: phase * 8)
                                        .offset(x: phase * 30)
                                } animation: { phase in
                                        .bouncy(duration: 0.2)
                                }
                        }
                        Spacer()
                        settingsButton
                    }
                }

                HStack(spacing: 12) {
                    searchField
                    if isSearching {
                        closeButton
                    }
                }

                if isSearching {
                    scopeChips
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .animation(.snappy(duration: 0.28), value: isSearching)
        // Matches the shell's own timing, so the button leaves as the panel
        // arrives rather than popping out a beat later.
        .animation(.snappy(duration: 0.28), value: sidebar?.isOpen)
        // Focus drives the state; the close button drives focus. Keeping the
        // dependency one-way avoids the two fighting each other.
        .onChange(of: searchFocused) { _, focused in
            if focused { isSearching = true }
        }
    }

    // MARK: - Resting state

    private struct PageEntry: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
    }

    private let favourites: [PageEntry] = [
        PageEntry(title: "Live TV", symbol: "antenna.radiowaves.left.and.right"),
        PageEntry(title: "Series", symbol: "tv"),
        PageEntry(title: "Movies", symbol: "film"),
    ]

    private let library: [PageEntry] = [
        PageEntry(title: "TV Guide", symbol: "calendar"),
        PageEntry(title: "Downloads", symbol: "arrow.down.circle"),
    ]

    private var pageMenu: some View {
        Menu {
            Section("♥ Favorites") {
                ForEach(favourites) { entry in
                    Button {
                        // TODO: wire to the matching tab once those screens exist.
                    } label: {
                        Label(entry.title, systemImage: entry.symbol)
                    }
                }
            }
            Section {
                ForEach(library) { entry in
                    Button {
                        // TODO: not built yet.
                    } label: {
                        Label(entry.title, systemImage: entry.symbol)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Home")
                    .font(.system(size: 28).bold())
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Pages")
    }

    /// Opens the iPad/Mac sidebar. Sized to match `settingsButton` so the two
    /// ends of the row balance.
    private func sidebarButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "sidebar.leading")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
        }
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Open sidebar")
    }

    @ViewBuilder
    private var settingsButton: some View {
        if !isRegularWidth {
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Settings")
        } else {
            Menu {
                Button {
                    // TODO: refresh playlist once that action exists.
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    // TODO: refresh playlist once that action exists.
                } label: {
                    Label("Manage Categories", systemImage: "list.bullet.circle")
                }
                Button {
                    // TODO: refresh playlist once that action exists.
                } label: {
                    Label("Show Locked", systemImage: "lock.circle")
                }
                Button {
                    // TODO: refresh playlist once that action exists.
                } label: {
                    Label("Playlist Settings", systemImage: "gear.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Playlist Settings")
        }
    }

    // MARK: - Search

    /// A plain `TextField` in glass rather than `.searchable`.
    ///
    /// `.searchable` owns its own placement — it lives under the navigation
    /// title and slides away on scroll — so it cannot be pinned here. A
    /// `TextField` bound straight to the model is also closer to the Flutter
    /// original, minus the `TextEditingController` to own and dispose.
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)

            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .foregroundStyle(.white)
                .submitLabel(.search)
                .plainTextEntry()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear text")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .glassEffect(.regular, in: Capsule())
    }

    /// Leaves search entirely — clears the query and restores the resting
    /// header. Distinct from the small ⓧ inside the field, which only clears the
    /// text and keeps the keyboard up.
    private var closeButton: some View {
        Button {
            searchText = ""
            searchFocused = false
            isSearching = false
        } label: {
            Image(systemName: "xmark")
                .font(.title2.weight(.medium))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
        }
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Close search")
        .transition(.scale.combined(with: .opacity))
    }

    private var scopeChips: some View {
        // **Its own container, with zero merge distance.**
        //
        // The header's outer `GlassEffectContainer(spacing: 20)` merges any
        // glass shapes within 20pt of each other — which is the whole point for
        // the pills up top, and exactly wrong here: the chips sit 10pt apart, so
        // they fused into one continuous blob with the selected one bleeding
        // into its neighbour. A nested container gives the row its own merge
        // group, and `spacing: 0` opts it out of merging entirely.
        GlassEffectContainer(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(HomeModel.SearchScope.allCases) { option in
                        Button {
                            scope = option
                        } label: {
                            Text(option.title)
                                .font(.body.weight(scope == option ? .semibold : .regular))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                        }
                        // A tint marks the selection. `.regular` glass on black
                        // looks near-identical whatever state it is in, so
                        // selection needs colour, not material, to read at all.
                        .glassEffect(
                            scope == option
                                ? .regular.tint(.accentColor).interactive()
                                : .regular.interactive(),
                            in: Capsule()
                        )
                    }

                    // A filter, not a scope — see `OnNowToggle`. Only under TV:
                    // Series and Movies are stubs, and there is nothing airing
                    // to narrow.
                    if scope == .tv {
                        Divider()
                            .frame(height: 24)
                            .padding(.horizontal, 2)
                        OnNowToggle(isOn: $onNowOnly)
                    }
                }
                .padding(.horizontal, 2)
            }
            // Chips run to the screen edge; the scroll view's own clipping would
            // otherwise shave the glass off the first and last capsule.
            .scrollClipDisabled()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

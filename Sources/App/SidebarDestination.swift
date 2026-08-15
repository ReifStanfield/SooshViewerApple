import SwiftUI

/// Where a sidebar can send you.
///
/// Shared by both shells: `TVSidebarShell` on tvOS and `SidebarShell` on a
/// regular-width iPad or Mac. The *chrome* forks per platform — a focus-driven
/// rail versus a tap-driven panel — but the set of places you can go is the
/// same, and two copies of this enum would drift the first time one gained an
/// entry.
enum SidebarDestination: Hashable, CaseIterable {
    case home, search, favorites, liveTV, series, movies, recordings, settings, addPlaylist

    var title: String {
        switch self {
        case .home: return "Home"
        case .search: return "Search"
        case .favorites: return "Favorites"
        case .liveTV: return "Live TV"
        case .series: return "Series"
        case .movies: return "Movies"
        case .recordings: return "Recordings"
        case .settings: return "Settings"
        case .addPlaylist: return "Add playlist"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .favorites: return "heart"
        case .liveTV: return "antenna.radiowaves.left.and.right"
        case .series: return "tv"
        case .movies: return "film"
        case .recordings: return "record.circle"
        case .settings: return "gearshape"
        case .addPlaylist: return "plus"
        }
    }
}

/// The sidebar, as a screen inside it sees one: whether it is open, and how to
/// open it.
///
struct SidebarControl {
    /// Whether the panel is showing. A screen's own open button should hide
    /// while it is: the content slides 300pt right, which lands the button just
    /// clear of the panel rather than under it, so it would otherwise sit there
    /// looking live next to an already-open sidebar.
    var isOpen: Bool

    /// Opens the panel.
    var open: () -> Void
}

extension EnvironmentValues {
    /// The sidebar hosting this screen, when there is one.
    ///
    /// **Nil is the signal.** It is nil on tvOS, nil at compact width where the
    /// tab bar is showing, and nil on every screen the shell does not host — so
    /// a view can render its button exactly when one would work, without
    /// checking the platform or the size class itself.
    @Entry var sidebar: SidebarControl?
}

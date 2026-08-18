import SwiftUI

/// Circular icon badge. Outlined and neutral by default; filled when a
/// `background` is supplied.
struct RoundIcon: View {
    let systemImage: String
    var background: Color?
    var foreground: Color?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16))
            .foregroundStyle(foreground ?? .secondary)
            .frame(width: 32, height: 32)
            .background {
                if let background {
                    Circle().fill(background)
                } else {
                    Circle().strokeBorder(.secondary.opacity(0.35), lineWidth: 1.2)
                }
            }
    }
}

/// Semantic tone for a status badge.
///
/// SwiftUI, like Material, has an error role but no success role, so these are
/// app-defined. Lift them into a shared file if anything else needs a status
/// badge (a connection indicator, a stream health dot).
enum StatusTone {
    case ok, warn, bad

    /// The app is pinned dark, so only the dark pair is carried over. The
    /// Flutter version keeps both because a green that reads well on a dark card
    /// is muddy on a light one — restore the light pair here if the app ever
    /// stops pinning.
    var colors: (background: Color, foreground: Color) {
        switch self {
        case .ok:
            return (Color(red: 0.106, green: 0.263, blue: 0.196),
                    Color(red: 0.431, green: 0.906, blue: 0.627))
        case .warn:
            return (Color(red: 0.290, green: 0.231, blue: 0.071),
                    Color(red: 0.965, green: 0.816, blue: 0.420))
        case .bad:
            return (Color(red: 0.290, green: 0.114, blue: 0.114),
                    Color(red: 0.941, green: 0.549, blue: 0.549))
        }
    }
}

/// A read-only status badge.
///
/// Deliberately not a `Button` or a chip: those carry interaction affordances
/// this has no use for. It is a label, so it owns its own colours.
struct StatusPill: View {
    let label: String
    let tone: StatusTone

    var body: some View {
        let colors = tone.colors
        Text(label)
            .font(.callout.weight(.semibold))
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(colors.background, in: Capsule())
    }
}

/// One tappable settings row: icon, title, optional subtitle, chevron.
///
/// `NavigationLink` supplies the chevron and the push, so this only builds the
/// label — the Flutter version draws its own `Icons.chevron_right` because
/// `M3EListItem` has no navigation role.
struct SettingsRowLabel: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    var iconBackground: Color?
    var iconForeground: Color?

    var body: some View {
        HStack(spacing: 12) {
            RoundIcon(
                systemImage: systemImage,
                background: iconBackground,
                foreground: iconForeground
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Stands in for a screen that does not exist yet.
///
/// The Flutter version shows a "not wired up yet" SnackBar. iOS has no snackbar,
/// and inventing one would be worse than saying so on the page you land on —
/// which is also what the unbuilt tabs and search scopes already do.
struct NotBuiltView: View {
    let title: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: "hammer",
            description: Text("\(title) isn't wired up yet.")
        )
        .navigationTitle(title)
        .inlineNavigationTitle()
    }
}

extension View {
    /// `navigationBarTitleDisplayMode` is iOS-only — tvOS has no navigation bar
    /// to configure, so the modifier does not exist there at all.
    ///
    /// Wrapped once rather than `#if`-ing four call sites: the platform
    /// difference is a fact about the modifier, not about any of the screens
    /// that want an inline title.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
            self.navigationBarTitleDisplayMode(.inline)
        #else
            // tvOS and macOS both have no navigation *bar* to set a display mode
            // on — the modifier is unavailable, not merely inert.
            self
        #endif
    }
}

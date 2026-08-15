import SwiftUI

/// The settings sheet.
///
/// The Flutter version needs `showAppSheet()` to choose between a Cupertino
/// sheet, a Material bottom sheet and a dialog by window size and platform, and
/// a `useNestedNavigation` flag to keep pushed detail pages inside the sheet.
/// Neither has an equivalent here:
///
/// * `.sheet` already adapts — full height on a phone, a centred form sheet on a
///   regular-width window — so there is no size branch to write.
/// * A `NavigationStack` *inside* the sheet is the nested navigation. Detail
///   pages push within it and Back pops within it.
///
/// That also deletes the trap `TopBar._defaultBack` exists for. In Flutter,
/// `Navigator.pop` on the sheet's first page succeeds, removes the only route
/// the nested Navigator has, and strands an empty one — a blank box. Here the
/// sheet's dismissal and the stack's back button are different mechanisms, so
/// the two cannot be confused: `Done` calls `dismiss()`, Back only exists when
/// there is a page to go back to.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// True only when this view is inside a presentation — the phone's sheet.
    ///
    /// The iPad sidebar shows Settings as a *destination*, where there is
    /// nothing to dismiss and `Done` would be a button that visibly does
    /// nothing. Gating on the environment keeps one `SettingsView` for both.
    @Environment(\.isPresented) private var isPresented

    var body: some View {
        NavigationStack {
            List {
                subscriptionSection
                playlistsSection
                advancedSection
            }
            .navigationTitle("Settings")
            .inlineNavigationTitle()
            .toolbar {
                if isPresented {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - Subscription

    private var subscriptionSection: some View {
        Section("Subscription") {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        Color(red: 1.0, green: 0.34, blue: 0.13),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("SOOSH PRO").font(.headline)
                    Text("Lifetime plan")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                StatusPill(label: "Active", tone: .ok)
            }
            .padding(.vertical, 4)

            // A second row rather than a divider inside one: `List` draws the
            // hairline between rows itself, which is what `_SectionCard` builds
            // by hand in Flutter.
            Text("Valid forever")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Playlists

    private var playlistsSection: some View {
        Section("Playlists") {
            NavigationLink {
                PlaylistDetailView()
            } label: {
                SettingsRowLabel(
                    systemImage: "link",
                    title: "Dispatcharr",
                    subtitle: Self.serverSummary,
                    // Filled, coloured tile marks the configured playlist; the
                    // rest of the list uses neutral outlined icons.
                    iconBackground: Color(red: 0.914, green: 0.118, blue: 0.388),
                    iconForeground: .white
                )
            }

            NavigationLink {
                NotBuiltView(title: "Add playlist")
            } label: {
                SettingsRowLabel(systemImage: "plus", title: "Add playlist")
            }
        }
    }

    /// The configured host, so the row shows what it points at.
    static var serverSummary: String {
        guard AppConfig.hasServer else { return "Not configured" }
        let host = URL(string: AppConfig.baseURL)?.host()
        return (host?.isEmpty == false) ? host! : AppConfig.baseURL
    }

    // MARK: - Advanced

    private static let advancedStubs: [(symbol: String, title: String)] = [
        ("slider.horizontal.3", "User interface"),
        ("play.circle", "Video player"),
        ("cloud", "Backup"),
        ("book", "EPG"),
        ("record.circle", "DVR server"),
    ]

    private var advancedSection: some View {
        Section("Advanced") {
            NavigationLink {
                GeneralSettingsView()
            } label: {
                SettingsRowLabel(systemImage: "gearshape", title: "General")
            }

            ForEach(Self.advancedStubs, id: \.title) { entry in
                NavigationLink {
                    NotBuiltView(title: entry.title)
                } label: {
                    SettingsRowLabel(systemImage: entry.symbol, title: entry.title)
                }
            }
        }
    }
}

/// Detail for the configured Dispatcharr playlist.
struct PlaylistDetailView: View {
    private var configured: Bool { AppConfig.hasServer }

    var body: some View {
        List {
            LabeledContent("Server") {
                Text(configured ? AppConfig.baseURL : "Not configured")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LabeledContent("Sign-in") {
                Text(AppConfig.hasCredentials ? AppConfig.username : "No credentials")
            }
            LabeledContent("Status") {
                StatusPill(
                    label: configured ? "Connected" : "Not set up",
                    tone: configured ? .ok : .warn
                )
            }
        }
        .navigationTitle("Dispatcharr")
        .inlineNavigationTitle()
    }
}

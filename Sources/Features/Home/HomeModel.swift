import Observation
import SwiftUI

/// The homepage's state and loading logic.
///
/// This is `_MyHomePageState` from `main.dart`, minus the widget tree. In
/// Flutter, state and build live in the same object; SwiftUI splits them —
/// `HomeView` is a value type that gets rebuilt constantly, so anything that
/// must survive a rebuild lives here instead.
///
/// `@Observable` (not the older `ObservableObject`) means SwiftUI tracks which
/// properties a given view body actually *read* and re-renders only those
/// views. There is no `setState` and no `@Published` — assigning to a property
/// is the notification.
@MainActor
@Observable
final class HomeModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var catalog: ChannelCatalog = .empty
    private(set) var guide: EPGGuide = .empty

    /// Bound to the header's search field. Filtering is local; the API's
    /// `search` param would mean a round trip per keystroke.
    var searchText: String = ""

    /// What the search field is searching over.
    ///
    /// Single-select, the standard reading of a chip row under a search field.
    /// `series` and `movies` are selectable rather than disabled — a greyed-out
    /// chip reads as broken, whereas selecting one and being told plainly that
    /// the screen does not exist yet is honest.
    var searchScope: SearchScope = .tv

    enum SearchScope: String, CaseIterable, Identifiable {
        /// One scope for live television, replacing the old Channels and
        /// Programs pair.
        ///
        /// Splitting them made the user answer a question they should not have
        /// to: "ESPN" is a channel *and* a word in programme titles, so the
        /// right chip depended on data they had not seen yet. One scope searches
        /// both and answers with the thing you actually want either way — the
        /// channel, in the guide.
        case tv, series, movies

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tv: return "TV"
            case .series: return "Series"
            case .movies: return "Movies"
            }
        }
    }

    /// Trimmed query, or nil when there is nothing to search for.
    var query: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Narrows a TV search to what is actually airing.
    ///
    /// Off by default: the guide holds ~24h, and "is this on at some point
    /// today" is the more common question. On, it answers "can I watch this
    /// right now".
    var onNowOnly = false

    /// Channels a TV search matches, by their own name or by anything in their
    /// schedule.
    ///
    /// **Unique by construction.** This filters the lineup rather than
    /// collecting programme hits, so a channel showing the same match six times
    /// today appears once — the previous Programs scope returned a row per
    /// airing and buried everything else under whichever channel repeated most.
    /// `contains` also short-circuits on the first hit instead of scanning a
    /// whole day per channel.
    ///
    /// Capped for the same reason the guide is: it is not virtualised, so the
    /// row count bounds the work as well as the height.
    var tvResults: [Channel] {
        guard let query else { return [] }
        let hits = catalog.visibleChannels.filter { channel in
            // **On Now drops the channel-name match too, deliberately.**
            //
            // The question the toggle asks is "is what I typed on right now",
            // and a channel called "MLB Baseball TV" currently showing a talk
            // show is not an answer to it. Keeping the name match would make the
            // toggle look broken on exactly the searches it exists for.
            if onNowOnly {
                guard let program = currentProgram(for: channel) else { return false }
                return matches(program, query)
            }
            if channel.displayName.localizedCaseInsensitiveContains(query) { return true }
            return guide.programs(for: channel).contains { matches($0, query) }
        }
        return Array(hits.prefix(Self.maxSearchRows))
    }

    private func matches(_ program: Program, _ query: String) -> Bool {
        program.displayTitle.localizedCaseInsensitiveContains(query)
            || program.displaySubTitle.localizedCaseInsensitiveContains(query)
    }

    static let maxSearchRows = 60

    let client: DispatcharrClient

    /// Shared with the guide so each logo is downloaded and decoded once, not
    /// once per surface that shows it.
    let logoPalette = LogoPalette()

    private let channels: ChannelRepository
    private let epg: EPGRepository

    init(client: DispatcharrClient) {
        self.client = client
        self.channels = ChannelRepository(client: client)
        self.epg = EPGRepository(client: client)
    }

    /// The carousel is a shortcut row, not the full lineup.
    private static let maxCarouselChannels = 20

    var carouselChannels: [Channel] {
        Array(catalog.visibleChannels.prefix(Self.maxCarouselChannels))
    }

    /// The category grid, straight from the catalog.
    var categories: [Category] { catalog.categories }

    /// A category's second line: how many channels this client actually holds.
    func subtitle(for category: Category) -> String {
        category.channelCount == 1 ? "1 channel" : "\(category.channelCount) channels"
    }

    /// Channels for the guide list, filtered by the search field.
    var guideChannels: [Channel] {
        let visible = catalog.visibleChannels
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visible }
        return visible.filter { channel in
            channel.displayName.localizedCaseInsensitiveContains(query)
                || (currentProgram(for: channel)?.displayTitle
                    .localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func currentProgram(for channel: Channel) -> Program? {
        guide.currentProgram(for: channel)
    }

    /// The subtitle line on a card: what's on now, else the channel number.
    func subtitle(for channel: Channel) -> String {
        if let title = currentProgram(for: channel)?.displayTitle, !title.isEmpty {
            return title
        }
        guard let number = channel.formattedChannelNumber else { return "No guide data" }
        return "Ch \(number)"
    }

    func load() async {
        guard AppConfig.hasServer else {
            state = .failed("No server configured. Fill in Config/Local.xcconfig.")
            return
        }
        state = .loading

        do {
            if await !client.isAuthenticated, AppConfig.hasCredentials {
                try await client.login(
                    username: AppConfig.username,
                    password: AppConfig.password
                )
            }

            // The full grid rather than current-programs: one call feeds both the
            // "now playing" line on cards and the running schedule the player
            // needs to advance. Heavier on a large lineup.
            async let catalogTask = channels.fetchCatalog()
            async let guideTask = epg.fetchGuide()

            // No `mounted` check needed. If the view goes away, SwiftUI cancels
            // the Task that `.task` created and these awaits throw
            // CancellationError instead of mutating a dead object.
            catalog = try await catalogTask
            guide = try await guideTask
            state = .loaded
        } catch is CancellationError {
            state = .idle
        } catch let error as APIError {
            state = .failed(
                error.isUnauthorized
                    ? "Login failed — check DISPATCHARR_USER / DISPATCHARR_PASS."
                    : (error.errorDescription ?? "Could not load channels.")
            )
        } catch {
            state = .failed("Could not reach \(AppConfig.baseURL).")
        }
    }
}

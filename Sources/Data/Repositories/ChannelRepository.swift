import Foundation

/// Channels plus their logos.
///
/// Channels reference logos by id only, so logos are fetched once into a map
/// and resolved locally rather than per card.
actor ChannelRepository {
    private let client: DispatcharrClient
    private let cache: CatalogCache?
    private var logosByID: [Int: Logo] = [:]
    private var logosLoaded = false
    private var groups: [ChannelGroup] = []
    private var groupsLoaded = false

    /// `cache` is optional so tests and previews can run without touching disk,
    /// and so a store that fails to open degrades to the network-only behaviour
    /// this repository had before rather than failing the launch.
    init(client: DispatcharrClient, cache: CatalogCache? = nil) {
        self.client = client
        self.cache = cache
    }

    /// `GET /api/channels/channels/` — every page.
    func fetchChannels(search: String? = nil) async throws -> [Channel] {
        try await client.getAllPages("/api/channels/channels/", as: Channel.self,
                                     query: ["search": search])
    }

    /// `GET /api/channels/logos/` — cached after the first call.
    func fetchLogos(forceRefresh: Bool = false) async throws -> [Int: Logo] {
        if logosLoaded, !forceRefresh { return logosByID }
        let logos: [Logo] = try await client.getAllPages("/api/channels/logos/")
        logosByID = Dictionary(logos.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        logosLoaded = true
        return logosByID
    }

    /// `GET /api/channels/groups/` — cached after the first call, like logos.
    ///
    /// Groups change when a playlist is re-synced, not while the app is open, so
    /// a per-launch fetch is enough; `forceRefresh` covers pull-to-refresh.
    func fetchGroups(forceRefresh: Bool = false) async throws -> [ChannelGroup] {
        if groupsLoaded, !forceRefresh { return groups }
        groups = try await client.getAllPages("/api/channels/groups/", as: ChannelGroup.self)
        groupsLoaded = true
        return groups
    }

    /// The last catalog written to disk, or nil on a first launch.
    ///
    /// **Cheap and non-throwing by design.** This is the half of
    /// stale-while-revalidate that runs before the network, so anything it could
    /// fail at is something the caller would ignore anyway — see `CatalogCache`.
    ///
    /// Deliberately not folded into `fetchCatalog`: the caller needs to *paint*
    /// between the two, which means it needs them as two calls rather than one
    /// that eventually returns the better answer.
    func cachedCatalog() async -> ChannelCatalog? {
        await cache?.load()
    }

    /// Channels, logos and groups together, so callers get a consistent set.
    ///
    /// Writes through to the cache on success. A `search` term is *not* cached:
    /// it is a filtered subset, and storing one would leave the next launch
    /// convinced the lineup is three channels long.
    func fetchCatalog(search: String? = nil) async throws -> ChannelCatalog {
        // Independent calls — `async let` runs them concurrently, the direct
        // equivalent of Dart's `Future.wait`.
        async let channels = fetchChannels(search: search)
        async let logos = fetchLogos()
        async let groups = fetchGroups()
        let catalog = ChannelCatalog(
            channels: try await channels,
            logosByID: try await logos,
            groups: try await groups
        )

        if search == nil {
            await cache?.save(catalog)
        }
        return catalog
    }
}

/// A channel list paired with the logo map and groups needed to render it.
struct ChannelCatalog: Sendable {
    let channels: [Channel]
    let logosByID: [Int: Logo]
    let groups: [ChannelGroup]

    /// Channels a user should actually see, in channel-number order.
    ///
    /// Computed once at construction rather than on each access — SwiftUI
    /// re-reads model properties on every body evaluation, so a sort hidden
    /// behind a `var` would run far more often than you'd expect.
    let visibleChannels: [Channel]

    /// Groups that have at least one visible channel, alphabetical.
    ///
    /// **Empty groups are dropped, and the count is the local one.** A provider
    /// ships far more groups than a given account can watch, and the server's
    /// `channel_count` includes channels hidden from output — so a card built
    /// from it would promise 40 channels and open onto 3, or onto nothing.
    let categories: [Category]

    init(channels: [Channel], logosByID: [Int: Logo], groups: [ChannelGroup] = []) {
        self.channels = channels
        self.logosByID = logosByID
        self.groups = groups

        let visible = channels
            .filter { !$0.isHiddenFromOutput }
            .sorted { lhs, rhs in
                let left = lhs.effectiveChannelNumber ?? .greatestFiniteMagnitude
                let right = rhs.effectiveChannelNumber ?? .greatestFiniteMagnitude
                if left != right { return left < right }
                return lhs.displayName.lowercased() < rhs.displayName.lowercased()
            }
        visibleChannels = visible

        // One pass over the lineup rather than one filter per group: a provider
        // can ship hundreds of groups, and the nested version is O(groups ×
        // channels) on every launch.
        let byGroupID = Dictionary(grouping: visible) { $0.effectiveChannelGroupID }
        categories = groups
            .compactMap { group in
                guard let members = byGroupID[group.id], !members.isEmpty else { return nil }
                return Category(group: group, channels: members)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static let empty = ChannelCatalog(channels: [], logosByID: [:], groups: [])

    /// Logo URL for a channel, or nil when it has none.
    func logoURL(for channel: Channel) -> URL? {
        guard let logoID = channel.effectiveLogoID else { return nil }
        return logosByID[logoID]?.bestURL
    }
}

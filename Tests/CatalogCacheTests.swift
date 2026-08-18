import Foundation
import SwiftData
import Testing

@testable import Soosh

/// Tests for the catalog disk cache.
///
/// **The thing worth asserting is the round trip, field by field.** A cache that
/// loses a field does not crash and does not log — it quietly serves a lineup
/// where some channels have lost their override, and the only symptom is a name
/// or a logo that is subtly wrong until the network refresh lands and corrects
/// it. That is close to invisible in a running app, so it gets pinned here.
@Suite("Catalog cache")
struct CatalogCacheTests {
    /// An in-memory store, so tests never touch the real cache on disk.
    private func makeCache() throws -> CatalogCache {
        let container = try ModelContainer(
            for: CachedChannel.self, CachedLogo.self, CachedGroup.self, CatalogStamp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return CatalogCache(modelContainer: container)
    }

    /// A channel with every override populated and distinct from its base field,
    /// so a mix-up between the two cannot pass.
    private func overriddenChannel() -> Channel {
        Channel(
            id: 7,
            uuid: "uuid-7",
            name: "Provider Name",
            channelNumber: 101,
            channelGroupID: 1,
            tvgID: "base.tvg",
            epgDataID: 11,
            logoID: 21,
            isHiddenFromOutput: false,
            isAdult: false,
            effectiveName: "Override Name",
            effectiveChannelNumberRaw: 202,
            effectiveLogoIDRaw: 22,
            effectiveTvgIDRaw: "override.tvg",
            effectiveEpgDataIDRaw: 12,
            effectiveChannelGroupIDRaw: 2
        )
    }

    private func plainChannel(id: Int, groupID: Int, hidden: Bool = false) -> Channel {
        Channel(
            id: id,
            uuid: "uuid-\(id)",
            name: "Channel \(id)",
            channelNumber: Double(id),
            channelGroupID: groupID,
            tvgID: nil, epgDataID: nil, logoID: nil,
            isHiddenFromOutput: hidden,
            isAdult: false,
            effectiveName: nil,
            effectiveChannelNumberRaw: nil,
            effectiveLogoIDRaw: nil,
            effectiveTvgIDRaw: nil,
            effectiveEpgDataIDRaw: nil,
            effectiveChannelGroupIDRaw: nil
        )
    }

    @Test("a channel survives the round trip with its overrides intact")
    func channelRoundTrips() async throws {
        let cache = try makeCache()
        let original = overriddenChannel()
        await cache.save(ChannelCatalog(channels: [original], logosByID: [:], groups: []))

        let loaded = try #require(await cache.load())
        let restored = try #require(loaded.channels.first)

        #expect(restored == original)

        // Spelled out as well as compared, because `==` passing on a type whose
        // overrides are all nil would prove nothing.
        #expect(restored.displayName == "Override Name")
        #expect(restored.effectiveChannelNumber == 202)
        #expect(restored.effectiveLogoID == 22)
        #expect(restored.effectiveTvgID == "override.tvg")
        #expect(restored.effectiveEpgDataID == 12)
        #expect(restored.effectiveChannelGroupID == 2)
        // The base fields must not have been overwritten by the coalesced ones.
        #expect(restored.name == "Provider Name")
        #expect(restored.channelNumber == 101)
    }

    @Test("an absent override stays absent rather than being baked in")
    func absentOverrideStaysAbsent() async throws {
        let cache = try makeCache()
        let plain = plainChannel(id: 3, groupID: 1)
        await cache.save(ChannelCatalog(channels: [plain], logosByID: [:], groups: []))

        let restored = try #require(await cache.load()?.channels.first)
        // Storing `displayName` into `effectiveName` would read back identically
        // here, so the assertion is on the raw override, not the display value.
        #expect(restored.persistedOverrides.name == nil)
        #expect(restored.displayName == "Channel 3")
    }

    @Test("derived data is recomputed on load, not persisted")
    func derivedDataIsRecomputed() async throws {
        let cache = try makeCache()
        let catalog = ChannelCatalog(
            channels: [
                plainChannel(id: 1, groupID: 10),
                plainChannel(id: 2, groupID: 10),
                plainChannel(id: 3, groupID: 99, hidden: true),
            ],
            logosByID: [5: Logo(id: 5, name: "L", url: "http://x/l.png", cacheURL: nil)],
            groups: [
                ChannelGroup(id: 10, name: "Sports", serverChannelCount: 400),
                // No visible members, so it must not become a category.
                ChannelGroup(id: 99, name: "Hidden", serverChannelCount: 9),
            ]
        )
        await cache.save(catalog)

        let loaded = try #require(await cache.load())
        #expect(loaded.visibleChannels.count == 2)
        #expect(loaded.categories.count == 1)
        #expect(loaded.categories.first?.name == "Sports")
        // The local count, not the server's inflated one.
        #expect(loaded.categories.first?.channelCount == 2)
        #expect(loaded.logosByID[5]?.bestURL?.absoluteString == "http://x/l.png")
    }

    @Test("saving replaces the previous catalog instead of accumulating")
    func saveReplaces() async throws {
        let cache = try makeCache()
        await cache.save(ChannelCatalog(
            channels: [plainChannel(id: 1, groupID: 1), plainChannel(id: 2, groupID: 1)],
            logosByID: [:], groups: []
        ))
        await cache.save(ChannelCatalog(
            channels: [plainChannel(id: 9, groupID: 1)], logosByID: [:], groups: []
        ))

        let loaded = try #require(await cache.load())
        // A removed channel must actually disappear — a merge that kept unknown
        // rows would leave dead channels on the home screen forever.
        #expect(loaded.channels.count == 1)
        #expect(loaded.channels.first?.id == 9)
    }

    @Test("an empty store is a miss, not an empty catalog")
    func emptyStoreIsAMiss() async throws {
        let cache = try makeCache()
        let loaded = await cache.load()
        // Returning `.empty` here would paint an empty home screen and call it
        // loaded, instead of falling through to the network.
        #expect(loaded == nil)
    }
}

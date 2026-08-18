import Foundation
import SwiftData

// The on-disk mirror of the channel catalog.
//
// **These are deliberately not the domain models.** `Channel`, `Logo` and
// `ChannelGroup` stay immutable `Sendable` structs, and these `@Model` classes
// shadow them. Three reasons, all of which bite immediately if you skip them:
//
// - `@Model` types are reference types and **not `Sendable`**. `Channel` crosses
//   from the `DispatcharrClient` actor to `@MainActor` on every load, and this
//   target builds with `SWIFT_STRICT_CONCURRENCY: complete`. Model classes
//   cannot make that trip; you would pass `PersistentIdentifier`s and re-fetch
//   on the far side, everywhere.
// - `ChannelCatalog` precomputes `visibleChannels` and `categories` in its
//   `init` precisely so SwiftUI does not re-sort on every body evaluation. That
//   is only safe because these are values.
// - The `Decodable` conformances are the LooseJSON tolerance layer for an API
//   that types numbers as strings. That does not want to be entangled with
//   persistence.
//
// So the price of the cache is this file: a flat, boring mirror, and two
// conversions. That is the whole cost, and it is paid once.
//
// **Every property has a default value.** SwiftData's lightweight migration
// requires it — without defaults, the first added field means hand-writing a
// migration plan.

@Model
final class CachedChannel {
    var id: Int = 0
    var uuid: String = ""
    var name: String = ""
    var channelNumber: Double?
    var channelGroupID: Int?
    var tvgID: String?
    var epgDataID: Int?
    var logoID: Int?
    var isHiddenFromOutput: Bool = false
    var isAdult: Bool = false

    // The `effective_*` overrides, stored raw rather than coalesced so a
    // round-trip through disk is identical to a round-trip through the API.
    var effectiveName: String?
    var effectiveChannelNumber: Double?
    var effectiveLogoID: Int?
    var effectiveTvgID: String?
    var effectiveEpgDataID: Int?
    var effectiveChannelGroupID: Int?

    init(_ channel: Channel) {
        let overrides = channel.persistedOverrides
        id = channel.id
        uuid = channel.uuid
        name = channel.name
        channelNumber = channel.channelNumber
        channelGroupID = channel.channelGroupID
        tvgID = channel.tvgID
        epgDataID = channel.epgDataID
        logoID = channel.logoID
        isHiddenFromOutput = channel.isHiddenFromOutput
        isAdult = channel.isAdult
        effectiveName = overrides.name
        effectiveChannelNumber = overrides.channelNumber
        effectiveLogoID = overrides.logoID
        effectiveTvgID = overrides.tvgID
        effectiveEpgDataID = overrides.epgDataID
        effectiveChannelGroupID = overrides.groupID
    }

    var channel: Channel {
        Channel(
            id: id,
            uuid: uuid,
            name: name,
            channelNumber: channelNumber,
            channelGroupID: channelGroupID,
            tvgID: tvgID,
            epgDataID: epgDataID,
            logoID: logoID,
            isHiddenFromOutput: isHiddenFromOutput,
            isAdult: isAdult,
            effectiveName: effectiveName,
            effectiveChannelNumberRaw: effectiveChannelNumber,
            effectiveLogoIDRaw: effectiveLogoID,
            effectiveTvgIDRaw: effectiveTvgID,
            effectiveEpgDataIDRaw: effectiveEpgDataID,
            effectiveChannelGroupIDRaw: effectiveChannelGroupID
        )
    }
}

@Model
final class CachedLogo {
    var id: Int = 0
    var name: String = ""
    var url: String = ""
    var cacheURL: String?

    init(_ logo: Logo) {
        id = logo.id
        name = logo.name
        url = logo.url
        cacheURL = logo.cacheURL
    }

    var logo: Logo {
        Logo(id: id, name: name, url: url, cacheURL: cacheURL)
    }
}

@Model
final class CachedGroup {
    var id: Int = 0
    var name: String = ""
    var serverChannelCount: Int?

    init(_ group: ChannelGroup) {
        id = group.id
        name = group.name
        serverChannelCount = group.serverChannelCount
    }

    var group: ChannelGroup {
        ChannelGroup(id: id, name: name, serverChannelCount: serverChannelCount)
    }
}

/// Provenance for the cached catalog.
///
/// **`serverURL` is the load-bearing field, not `fetchedAt`.** Point the app at
/// a different Dispatcharr and the previous server's lineup is not stale, it is
/// *wrong* — every channel id, logo id and group id belongs to someone else's
/// installation. A mismatch discards the cache outright.
///
/// There is deliberately **no expiry**. The catalog is revalidated over the
/// network on every launch anyway, so a time limit would only decide how much
/// of nothing to show while offline. A month-old lineup beats an empty screen,
/// and the refresh corrects it the moment the network answers.
@Model
final class CatalogStamp {
    var fetchedAt: Date = Date.distantPast
    var serverURL: String = ""

    init(serverURL: String, fetchedAt: Date = .now) {
        self.serverURL = serverURL
        self.fetchedAt = fetchedAt
    }
}

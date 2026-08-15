import Foundation

/// A channel group from `GET /api/channels/groups/` — what the UI calls a
/// category.
///
/// Dispatcharr has no separate "category" concept: the group a channel belongs
/// to (`Channel.effectiveChannelGroupID`) is the categorisation the provider
/// ships, and the names are the usual `Sports`, `News`, `US | Entertainment`.
///
/// The endpoint returns a bare array, not a DRF page — `getAllPages` handles
/// that shape, so it needs no special casing here.
struct ChannelGroup: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String

    /// The server's own count, across the *whole* installation.
    ///
    /// Declared `type: string` in the OpenAPI schema even though it is a number,
    /// which is why it goes through `looseInt` like everything else here.
    ///
    /// It counts channels this client never shows — hidden ones included — so
    /// the UI counts the lineup it actually holds instead
    /// (`ChannelCatalog.categories`). Kept because it is the only signal
    /// available before the channel list lands.
    let serverChannelCount: Int?
}

extension ChannelGroup: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name
        case channelCount = "channel_count"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.looseInt(.id) ?? 0
        name = container.looseString(.name) ?? ""
        serverChannelCount = container.looseInt(.channelCount)
    }
}

/// A category as the homepage draws it: the group plus the channels this client
/// actually holds for it.
///
/// Built once in `ChannelCatalog` rather than filtered per card — a card that
/// re-scanned the lineup on each body evaluation would run that filter once per
/// group per render.
struct Category: Identifiable, Hashable, Sendable {
    let group: ChannelGroup
    let channels: [Channel]

    var id: Int { group.id }
    var name: String { group.name }
    var channelCount: Int { channels.count }
}

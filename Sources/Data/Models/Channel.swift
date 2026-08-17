import Foundation

/// A channel from `GET /api/channels/channels/`.
///
/// Dispatcharr keeps two parallel sets of fields: the raw provider values and
/// the `effective_*` values, which fold in any per-channel override. **UI reads
/// the `effective*` properties, never the raw ones.**
///
/// `Identifiable` because SwiftUI's `ForEach` needs a stable identity per row;
/// `Sendable` because these cross from the networking actor to `@MainActor`.
struct Channel: Identifiable, Hashable, Sendable {
    let id: Int
    let uuid: String
    let name: String
    let channelNumber: Double?
    let channelGroupID: Int?
    let tvgID: String?
    let epgDataID: Int?
    let logoID: Int?
    let isHiddenFromOutput: Bool
    let isAdult: Bool

    // Overrides, already coerced at decode time.
    private let effectiveName: String?
    private let effectiveChannelNumberRaw: Double?
    private let effectiveLogoIDRaw: Int?
    private let effectiveTvgIDRaw: String?
    private let effectiveEpgDataIDRaw: Int?
    private let effectiveChannelGroupIDRaw: Int?

    /// Display name, honouring any override.
    var displayName: String {
        if let effectiveName, !effectiveName.isEmpty { return effectiveName }
        return name
    }

    var effectiveChannelNumber: Double? { effectiveChannelNumberRaw ?? channelNumber }
    var effectiveLogoID: Int? { effectiveLogoIDRaw ?? logoID }

    /// The key that joins this channel to EPG programmes. `Program` carries no
    /// channel foreign key — only `tvg_id`.
    var effectiveTvgID: String? { effectiveTvgIDRaw ?? tvgID }

    var effectiveEpgDataID: Int? { effectiveEpgDataIDRaw ?? epgDataID }
    var effectiveChannelGroupID: Int? { effectiveChannelGroupIDRaw ?? channelGroupID }

    /// `12` rather than `12.0` — channel numbers arrive as doubles.
    var formattedChannelNumber: String? {
        guard let number = effectiveChannelNumber else { return nil }
        return number == number.rounded()
            ? String(Int(number))
            : String(format: "%.1f", number)
    }

    /// Full initialiser, for rebuilding a channel from the disk cache.
    ///
    /// The compiler-generated memberwise init is `private`, because the
    /// `effective*Raw` fields are — which is what `previewMock` below uses, and
    /// which stops at this file's edge. `CachedChannel` lives in another file
    /// and needs a way in.
    init(
        id: Int,
        uuid: String,
        name: String,
        channelNumber: Double?,
        channelGroupID: Int?,
        tvgID: String?,
        epgDataID: Int?,
        logoID: Int?,
        isHiddenFromOutput: Bool,
        isAdult: Bool,
        effectiveName: String?,
        effectiveChannelNumberRaw: Double?,
        effectiveLogoIDRaw: Int?,
        effectiveTvgIDRaw: String?,
        effectiveEpgDataIDRaw: Int?,
        effectiveChannelGroupIDRaw: Int?
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.channelNumber = channelNumber
        self.channelGroupID = channelGroupID
        self.tvgID = tvgID
        self.epgDataID = epgDataID
        self.logoID = logoID
        self.isHiddenFromOutput = isHiddenFromOutput
        self.isAdult = isAdult
        self.effectiveName = effectiveName
        self.effectiveChannelNumberRaw = effectiveChannelNumberRaw
        self.effectiveLogoIDRaw = effectiveLogoIDRaw
        self.effectiveTvgIDRaw = effectiveTvgIDRaw
        self.effectiveEpgDataIDRaw = effectiveEpgDataIDRaw
        self.effectiveChannelGroupIDRaw = effectiveChannelGroupIDRaw
    }

    /// The raw override values, for persistence.
    ///
    /// **Raw, not coalesced.** Storing `displayName` into `effectiveName` would
    /// read back identically today, but it silently converts "the provider named
    /// this and there is no override" into "there is an override" — so a later
    /// server-side rename would stop taking effect for cached channels only.
    var persistedOverrides: (
        name: String?,
        channelNumber: Double?,
        logoID: Int?,
        tvgID: String?,
        epgDataID: Int?,
        groupID: Int?
    ) {
        (
            effectiveName,
            effectiveChannelNumberRaw,
            effectiveLogoIDRaw,
            effectiveTvgIDRaw,
            effectiveEpgDataIDRaw,
            effectiveChannelGroupIDRaw
        )
    }
}

extension Channel: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, uuid, name
        case channelNumber = "channel_number"
        case channelGroupID = "channel_group_id"
        case tvgID = "tvg_id"
        case epgDataID = "epg_data_id"
        case logoID = "logo_id"
        case isAdult = "is_adult"
        case isHiddenFromOutput = "hidden_from_output"
        case effectiveName = "effective_name"
        case effectiveChannelNumber = "effective_channel_number"
        case effectiveLogoID = "effective_logo_id"
        case effectiveTvgID = "effective_tvg_id"
        case effectiveEpgDataID = "effective_epg_data_id"
        case effectiveChannelGroupID = "effective_channel_group_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.looseInt(.id) ?? 0
        uuid = container.looseString(.uuid) ?? ""
        name = container.looseString(.name) ?? ""
        channelNumber = container.looseDouble(.channelNumber)
        channelGroupID = container.looseInt(.channelGroupID)
        tvgID = container.looseString(.tvgID)
        epgDataID = container.looseInt(.epgDataID)
        logoID = container.looseInt(.logoID)
        isAdult = container.looseBool(.isAdult)
        isHiddenFromOutput = container.looseBool(.isHiddenFromOutput)
        effectiveName = container.looseString(.effectiveName)
        // Typed `string` in the schema even when numeric — a plain
        // `decode(Int.self)` throws on real data. Hence the loose accessors.
        effectiveChannelNumberRaw = container.looseDouble(.effectiveChannelNumber)
        effectiveLogoIDRaw = container.looseInt(.effectiveLogoID)
        effectiveTvgIDRaw = container.looseString(.effectiveTvgID)
        effectiveEpgDataIDRaw = container.looseInt(.effectiveEpgDataID)
        effectiveChannelGroupIDRaw = container.looseInt(.effectiveChannelGroupID)
    }
}
#if DEBUG
extension Channel {
    /// A convenient mock for SwiftUI Previews.
    static var previewMock: Channel {
        Channel(
            id: 1,
            uuid: UUID().uuidString,
            name: "Demo Channel",
            channelNumber: 101,
            channelGroupID: nil,
            tvgID: "demo.tvg",
            epgDataID: nil,
            logoID: nil,
            isHiddenFromOutput: false,
            isAdult: false,
            effectiveName: nil,
            effectiveChannelNumberRaw: nil,
            effectiveLogoIDRaw: nil,
            effectiveTvgIDRaw: nil,
            effectiveEpgDataIDRaw: nil,
            effectiveChannelGroupIDRaw: nil
        )
    }
}
#endif

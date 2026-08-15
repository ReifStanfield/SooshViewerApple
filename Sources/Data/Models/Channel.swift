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

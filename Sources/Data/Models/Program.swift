import Foundation

/// An EPG programme from `/api/epg/grid/`.
///
/// `tvgID` is the *only* link back to a channel — there is no channel foreign
/// key on this record. See `EPGGuide` for the join.
struct Program: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let startTime: Date
    let endTime: Date
    let subTitle: String?
    let programDescription: String?
    let tvgID: String?
    let iconURL: String?

    // Returned by /api/epg/grid/ but absent from the documented ProgramData
    // schema, so they default off rather than being required.
    let season: Int?
    let episode: Int?
    let isNew: Bool
    /// A live broadcast (sport, news) rather than a recording. Drives the badge.
    let isLive: Bool
    let isPremiere: Bool
    let isFinale: Bool

    /// A stand-in the EPG never sent, standing for a channel it says nothing
    /// about.
    ///
    /// A stored flag rather than a sentinel id. The obvious trick — a negative
    /// id — would make every `id` comparison in the app quietly load-bearing,
    /// and nothing at the point of use would say so. It defaults to false, so
    /// the memberwise initialiser and the decoder both carry on unchanged.
    var isPlaceholder: Bool = false

    /// Ornament-free title, for display. Lives on the model so the guide, the
    /// carousel and the player overlay cannot drift apart.
    var displayTitle: String { title.strippedOfNonASCII }
    var displaySubTitle: String { (subTitle ?? "").strippedOfNonASCII }

    /// `S3 E4`, or nil when the programme carries no season/episode numbers.
    var episodeLabel: String? {
        let parts = [season.map { "S\($0)" }, episode.map { "E\($0)" }].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

    func isAiring(at moment: Date = .now) -> Bool {
        moment >= startTime && moment < endTime
    }

    /// 0…1 through the programme; 0 for zero-length entries.
    func progress(at moment: Date = .now) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(moment.timeIntervalSince(startTime) / duration, 0), 1)
    }

    /// A filler entry spanning `start`…`end` for a channel with no EPG.
    ///
    /// Synthesised rather than special-cased in the guide, so a channel the EPG
    /// has never heard of still has a row you can see, tap, and open details
    /// for. Everything downstream — the block, the detail sheet, the tap
    /// handler — takes a `Program` and does not need to know this one is made
    /// up; only the colour does.
    static func placeholder(for channel: Channel, from start: Date, to end: Date) -> Program {
        Program(
            // Real ids come from the EPG and are only ever compared within a
            // channel's own schedule, which this is the entirety of.
            id: 0,
            title: "No guide data",
            startTime: start,
            endTime: end,
            subTitle: nil,
            programDescription: nil,
            tvgID: channel.effectiveTvgID,
            iconURL: nil,
            season: nil,
            episode: nil,
            isNew: false,
            isLive: false,
            isPremiere: false,
            isFinale: false,
            isPlaceholder: true
        )
    }
}

extension Program: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, title, season, episode
        case startTime = "start_time"
        case endTime = "end_time"
        case subTitle = "sub_title"
        case programDescription = "description"
        case tvgID = "tvg_id"
        case iconURL = "epg_icon_url"
        case isNew = "is_new"
        case isLive = "is_live"
        case isPremiere = "is_premiere"
        case isFinale = "is_finale"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.looseInt(.id) ?? 0
        title = container.looseString(.title) ?? ""
        let now = Date.now
        startTime = container.looseDate(.startTime) ?? now
        endTime = container.looseDate(.endTime) ?? now
        subTitle = container.looseString(.subTitle)
        programDescription = container.looseString(.programDescription)
        tvgID = container.looseString(.tvgID)
        iconURL = container.looseString(.iconURL)
        season = container.looseInt(.season)
        episode = container.looseInt(.episode)
        isNew = container.looseBool(.isNew)
        isLive = container.looseBool(.isLive)
        isPremiere = container.looseBool(.isPremiere)
        isFinale = container.looseBool(.isFinale)
    }
}

/// An EPG channel record from `GET /api/epg/epgdata/`.
///
/// Bridges a channel's `epg_data_id` to the `tvg_id` that programmes key off.
struct EPGData: Identifiable, Hashable, Sendable, Decodable {
    let id: Int
    let name: String
    let tvgID: String?
    let iconURL: String?

    private enum CodingKeys: String, CodingKey {
        case id, name
        case tvgID = "tvg_id"
        case iconURL = "icon_url"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.looseInt(.id) ?? 0
        name = container.looseString(.name) ?? ""
        tvgID = container.looseString(.tvgID)
        iconURL = container.looseString(.iconURL)
    }
}

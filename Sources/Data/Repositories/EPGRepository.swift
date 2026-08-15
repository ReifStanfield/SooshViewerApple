import Foundation

/// EPG programmes, keyed the way the API actually links them.
actor EPGRepository {
    private let client: DispatcharrClient

    init(client: DispatcharrClient) {
        self.client = client
    }

    /// `GET /api/epg/grid/` — previous hour, now, and the next 24 hours.
    ///
    /// One unpaginated array covering the whole window, so it is the right call
    /// for a guide screen. Do **not** use `/api/epg/programs/`, which returns
    /// every programme ever imported.
    ///
    /// Also pulls `/api/epg/epgdata/` so the guide can bridge channels whose own
    /// tvg_id is blank or disagrees with the EPG source.
    func fetchGuide() async throws -> EPGGuide {
        async let programs: [Program] = client.getList("/api/epg/grid/")
        async let epgData: [EPGData] = client.getAllPages("/api/epg/epgdata/")
        return EPGGuide(programs: try await programs, epgData: try await epgData)
    }
}

/// Programmes indexed by `tvg_id`, with the channel joins applied.
///
/// Every channel↔programme join in the app funnels through here rather than
/// being re-derived in views.
struct EPGGuide: Sendable {
    /// Normalised tvg_id → that channel's programmes, ascending by start time.
    private let programsByTvgID: [String: [Program]]
    /// epg_data_id → normalised tvg_id, from `/api/epg/epgdata/`.
    private let tvgIDByEpgDataID: [Int: String]
    /// How many programmes the API returned, before any tvg_id filtering.
    /// Distinguishes "the EPG is empty" from "the EPG returned programmes that
    /// carry no tvg_id" — identical from `programsByTvgID` alone.
    let totalPrograms: Int

    static let empty = EPGGuide(programs: [], epgData: [])

    init(programs: [Program], epgData: [EPGData] = []) {
        var byTvgID: [String: [Program]] = [:]
        for program in programs {
            let key = Self.normalise(program.tvgID)
            guard !key.isEmpty else { continue }
            byTvgID[key, default: []].append(program)
        }
        for key in byTvgID.keys {
            byTvgID[key]?.sort { $0.startTime < $1.startTime }
        }
        programsByTvgID = byTvgID

        tvgIDByEpgDataID = Dictionary(
            epgData.compactMap { record in
                let key = Self.normalise(record.tvgID)
                return key.isEmpty ? nil : (record.id, key)
            },
            uniquingKeysWith: { _, last in last }
        )
        totalPrograms = programs.count
    }

    /// Canonical form of a tvg_id for matching.
    ///
    /// XMLTV ids routinely differ in case and surrounding whitespace between an
    /// EPG source and the channel lineup ("ESPN.us" vs "espn.us"), which would
    /// otherwise silently produce an empty guide.
    static func normalise(_ tvgID: String?) -> String {
        (tvgID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isEmpty: Bool { programsByTvgID.isEmpty }

    /// The API returned programmes, but none had a tvg_id to join on.
    var hasProgramsWithoutTvgIDs: Bool { totalPrograms > 0 && programsByTvgID.isEmpty }

    /// Every programme for a channel.
    ///
    /// Tries the channel's own tvg_id first, then falls back to its
    /// `epg_data_id` resolved through EPGData. The fallback matters because a
    /// channel's tvg_id is provider metadata that is often blank or disagrees
    /// with the EPG source, whereas `epg_data_id` is the explicit link the user
    /// (or EPG auto-match) established.
    func programs(for channel: Channel) -> [Program] {
        let direct = Self.normalise(channel.effectiveTvgID)
        if !direct.isEmpty, let matched = programsByTvgID[direct] {
            return matched
        }
        if let epgDataID = channel.effectiveEpgDataID,
           let bridged = tvgIDByEpgDataID[epgDataID] {
            return programsByTvgID[bridged] ?? []
        }
        return []
    }

    /// What is airing on `channel` at `moment`.
    func currentProgram(for channel: Channel, at moment: Date = .now) -> Program? {
        for program in programs(for: channel) {
            if program.isAiring(at: moment) { return program }
            // Sorted ascending, so once we pass `moment` nothing later matches.
            if program.startTime > moment { break }
        }
        return nil
    }

    func nextProgram(for channel: Channel, after moment: Date = .now) -> Program? {
        programs(for: channel).first { $0.startTime > moment }
    }
}

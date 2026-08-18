import Observation
import SwiftUI

/// The set of channels playing at once, and which one you can hear.
///
/// **Owned by `RootView`, above the navigation stack, and that placement is the
/// whole design.** A tile has to keep playing while you browse home, open a
/// category and pick the next channel — so the players cannot belong to any
/// screen you can navigate away from. `PlayerView` creates and destroys a
/// `PlayerModel` in its `.task`; these outlive every view.
///
/// **Each tile is a whole pipeline: an upstream connection, a rewrap session
/// with its own loopback server and ~19MB sliding window, and an `AVPlayer`
/// decoding HD video.** That is the real constraint here, not layout. The
/// provider enforces a connection limit — the same one that answers
/// "All active M3U profiles have reached maximum connection limits" — so
/// `maxTiles` is a guard against locking yourself out of your own service, not
/// a UI preference.
@MainActor
@Observable
final class MultiviewModel {
    struct Tile: Identifiable {
        let id = UUID()
        let channel: Channel
        let logoURL: URL?
        let model: PlayerModel
    }

    /// How the tiles are arranged when the grid has the screen.
    enum Layout: Equatable {
        /// Equal cells: two side by side, four as a 2x2.
        case grid
        /// One stream at full size with the others small along its bottom edge.
        case focus
    }

    /// Whether the grid is a corner window or has taken the screen.
    ///
    /// **Driven by count, with one deliberate exception.** One stream is a thing
    /// you keep an eye on while using the app, so it floats in the corner. Two
    /// or more is the thing you are doing, so it takes the screen. The exception
    /// is `browse`, which steps out of the way *without* dropping to one tile so
    /// you can pick the next channel.
    enum Presentation: Equatable {
        case corner
        case expanded
        case browse
    }

    private(set) var tiles: [Tile] = []

    private(set) var layout: Layout = .grid

    /// The tile in the large slot under `.focus`. Nil means the first one.
    private(set) var focusedTileID: Tile.ID?

    /// Set while the viewer is picking another channel, so the grid gets out of
    /// the way without being torn down.
    private var isBrowsing = false

    var presentation: Presentation {
        if isBrowsing { return .browse }
        return tiles.count >= 2 ? .expanded : .corner
    }

    /// The tile shown large under `.focus`.
    var focusedTile: Tile? {
        tiles.first { $0.id == focusedTileID } ?? tiles.first
    }

    var secondaryTiles: [Tile] {
        tiles.filter { $0.id != focusedTile?.id }
    }

    // MARK: - Presentation

    func toggleLayout() {
        layout = layout == .grid ? .focus : .grid
        // Entering focus without a chosen tile would otherwise promote whichever
        // happens to be first, which is rarely the one being watched.
        if layout == .focus, focusedTileID == nil {
            focusedTileID = audibleTileID ?? tiles.first?.id
        }
    }

    func focus(_ id: Tile.ID) {
        focusedTileID = id
        makeAudible(id)
    }

    /// Steps aside so another channel can be picked.
    func beginBrowsing() { isBrowsing = true }

    /// Comes back without having picked anything.
    ///
    /// **Without this, browsing is a trap.** The grid hides itself so you can
    /// see the app, and if you then change your mind there is nothing on screen
    /// to bring it back — several streams still playing and no way to reach
    /// them. The pill in the corner during `.browse` calls this.
    func endBrowsing() { isBrowsing = false }

    /// The tile you can hear. Everything else is muted.
    ///
    /// **Not a preference — a requirement.** Four streams at once is four audio
    /// tracks mixed together, which is unintelligible. One audible tile is what
    /// every multiview does, and the choice of *which* is what tapping a tile
    /// changes.
    private(set) var audibleTileID: Tile.ID?

    /// Whether tiles are on screen and channel taps should add to them.
    var isActive: Bool { !tiles.isEmpty }

    /// Ceiling on simultaneous streams.
    ///
    /// Four is a judgement, not a measurement: it is the largest grid that stays
    /// readable in a corner, and four upstream connections is already enough to
    /// trip a modest provider limit. Raising it costs connections first and
    /// decode second.
    static let maxTiles = 4

    var isFull: Bool { tiles.count >= Self.maxTiles }

    // MARK: - Adding and removing

    /// Adds a channel, unless it is already showing or the grid is full.
    ///
    /// Returns the tile it added or found, so a caller can focus it.
    @discardableResult
    func add(channel: Channel, home: HomeModel) -> Tile? {
        add(
            channel: channel,
            streamURL: home.client.streamURL(forChannelUUID: channel.uuid),
            programs: home.guide.programs(for: channel),
            logoURL: home.catalog.logoURL(for: channel)
        )
    }

    /// The same, for callers that already hold the pieces.
    ///
    /// `PlayerView` is one: it was handed a stream URL and a programme list when
    /// it was pushed, and has no `HomeModel` to ask. Deriving them a second time
    /// would need a dependency it does not otherwise have.
    @discardableResult
    func add(
        channel: Channel,
        streamURL: URL?,
        programs: [Program],
        logoURL: URL?
    ) -> Tile? {
        // Tapping a channel that is already tiled should move your attention to
        // it, not start a second connection to the same stream.
        if let existing = tiles.first(where: { $0.channel.id == channel.id }) {
            makeAudible(existing.id)
            return existing
        }
        guard !isFull else { return nil }

        let player = PlayerModel(
            channelName: channel.displayName,
            streamURL: streamURL,
            programs: programs
        )
        let tile = Tile(channel: channel, logoURL: logoURL, model: player)
        tiles.append(tile)

        player.startTicking()
        player.connect()

        // The newest tile takes the sound: you just asked for it.
        makeAudible(tile.id)
        // Picking a channel is the end of picking a channel.
        isBrowsing = false
        return tile
    }

    /// Tiles a player that is **already running**, taking ownership of it.
    ///
    /// **This is what the pop-out control uses, and the distinction is not
    /// cosmetic.** Building a fresh `PlayerModel` for the channel you are
    /// already watching opens a second upstream connection to the same stream
    /// and waits out another join — the provider counts both, and for a few
    /// seconds one channel occupies two of a small number of slots. Handing the
    /// running player over costs nothing and the picture never stops.
    ///
    /// The caller must not tear this model down afterwards: ownership moved.
    @discardableResult
    func adopt(channel: Channel, logoURL: URL?, model: PlayerModel) -> Tile {
        if let existing = tiles.first(where: { $0.channel.id == channel.id }) {
            makeAudible(existing.id)
            return existing
        }
        let tile = Tile(channel: channel, logoURL: logoURL, model: model)
        tiles.append(tile)
        makeAudible(tile.id)
        isBrowsing = false
        return tile
    }

    func remove(_ id: Tile.ID) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = tiles.remove(at: index)

        // **Torn down explicitly, not left to ARC.** The tile owns an upstream
        // connection the provider is counting; releasing the object eventually
        // is not the same as giving the connection back now.
        Task { await tile.model.teardown() }

        if audibleTileID == id {
            audibleTileID = tiles.last?.id
            applyMuting()
        }
        if focusedTileID == id {
            focusedTileID = tiles.first?.id
        }
    }

    func closeAll() {
        for tile in tiles {
            Task { await tile.model.teardown() }
        }
        tiles.removeAll()
        audibleTileID = nil
        focusedTileID = nil
        isBrowsing = false
        layout = .grid
    }

    // MARK: - Audio

    func makeAudible(_ id: Tile.ID) {
        audibleTileID = id
        applyMuting()
    }

    private func applyMuting() {
        for tile in tiles {
            tile.model.avEngine?.setMuted(tile.id != audibleTileID)
        }
    }
}

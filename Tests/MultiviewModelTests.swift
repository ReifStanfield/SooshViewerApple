import Foundation
import Testing

@testable import Soosh

/// Tests for the multiview session.
///
/// **These use channels with no stream URL on purpose.** `PlayerModel` fails
/// such a channel immediately and without touching the network, so the session's
/// bookkeeping — what is tiled, what is audible, what happens at the cap — can
/// be exercised without opening a single upstream connection. That matters more
/// here than usual: the provider enforces a connection limit, and a test suite
/// that opened four live streams per run would lock the account out of its own
/// service.
@MainActor
@Suite("Multiview session")
struct MultiviewModelTests {
    private func channel(id: Int, name: String) -> Channel {
        Channel(
            id: id,
            uuid: "uuid-\(id)",
            name: name,
            channelNumber: Double(id),
            channelGroupID: 1,
            tvgID: nil, epgDataID: nil, logoID: nil,
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

    @discardableResult
    private func add(_ model: MultiviewModel, _ channel: Channel) -> MultiviewModel.Tile? {
        model.add(channel: channel, streamURL: nil, programs: [], logoURL: nil)
    }

    @Test("adding a channel tiles it and gives it the sound")
    func addingTiles() {
        let model = MultiviewModel()
        #expect(!model.isActive)

        let tile = add(model, channel(id: 1, name: "One"))
        #expect(model.isActive)
        #expect(model.tiles.count == 1)
        // The newest tile takes the sound: it is the one just asked for.
        #expect(model.audibleTileID == tile?.id)
    }

    @Test("the newest tile takes the sound from the previous one")
    func newestTileIsAudible() {
        let model = MultiviewModel()
        add(model, channel(id: 1, name: "One"))
        let second = add(model, channel(id: 2, name: "Two"))
        #expect(model.audibleTileID == second?.id)
    }

    @Test("tapping an already-tiled channel focuses it rather than opening it twice")
    func duplicateFocusesInstead() {
        let model = MultiviewModel()
        let first = add(model, channel(id: 1, name: "One"))
        add(model, channel(id: 2, name: "Two"))

        let again = add(model, channel(id: 1, name: "One"))

        // A second connection to a stream already playing would cost an upstream
        // slot to show the same picture twice.
        #expect(model.tiles.count == 2)
        #expect(again?.id == first?.id)
        #expect(model.audibleTileID == first?.id)
    }

    @Test("the grid stops at the cap")
    func capped() {
        let model = MultiviewModel()
        for index in 1...MultiviewModel.maxTiles {
            #expect(add(model, channel(id: index, name: "Ch\(index)")) != nil)
        }
        #expect(model.isFull)

        // Refused rather than silently evicting someone: each tile is an
        // upstream connection, and the cap is what stops multiview from
        // exhausting the provider's limit.
        let overflow = add(model, channel(id: 99, name: "Overflow"))
        #expect(overflow == nil)
        #expect(model.tiles.count == MultiviewModel.maxTiles)
    }

    @Test("removing the audible tile hands the sound to another")
    func removingAudibleMovesSound() {
        let model = MultiviewModel()
        let first = add(model, channel(id: 1, name: "One"))
        let second = add(model, channel(id: 2, name: "Two"))
        #expect(model.audibleTileID == second?.id)

        model.remove(second!.id)

        #expect(model.tiles.count == 1)
        // Silence with a tile still on screen reads as broken audio.
        #expect(model.audibleTileID == first?.id)
    }

    @Test("removing a background tile leaves the sound where it is")
    func removingBackgroundKeepsSound() {
        let model = MultiviewModel()
        let first = add(model, channel(id: 1, name: "One"))
        let second = add(model, channel(id: 2, name: "Two"))

        model.remove(first!.id)

        #expect(model.audibleTileID == second?.id)
    }

    @Test("closing all leaves nothing playing")
    func closeAllEmpties() {
        let model = MultiviewModel()
        add(model, channel(id: 1, name: "One"))
        add(model, channel(id: 2, name: "Two"))

        model.closeAll()

        #expect(model.tiles.isEmpty)
        #expect(!model.isActive)
        #expect(model.audibleTileID == nil)
    }
}

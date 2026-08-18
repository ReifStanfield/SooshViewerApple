import AVFoundation
import SwiftUI

/// The tiles, drawn over whatever screen you are on.
///
/// **An overlay rather than a screen.** The point of multiview is that the app
/// carries on underneath — you browse home, open a category, pick the next
/// channel — so this cannot be a destination you navigate *to*. It sits above
/// the navigation stack in `RootView` and never participates in it.
struct MultiviewOverlay: View {
    @Bindable var multiview: MultiviewModel

    /// Tile width. Two columns of these plus the gaps is the corner cluster's
    /// full width, which is what bounds how far it intrudes on the app.
    private let tileWidth: CGFloat = 240

    var body: some View {
        if multiview.isActive {
            VStack(alignment: .trailing, spacing: 10) {
                Spacer()
                // **Wrapped in an HStack with a leading Spacer.** A `LazyVGrid`
                // expands to whatever width it is offered and centres its
                // columns inside it, so on its own the tiles sat in the middle
                // of the screen however the stack was aligned. The Spacer is
                // what actually pushes them into the corner.
                //
                // Two columns, filling top-to-bottom: a single row would run off
                // a phone, and a free-floating grid would need drag state the
                // feature does not have yet.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(tileWidth), spacing: 10),
                            count: multiview.tiles.count > 1 ? 2 : 1
                        ),
                        spacing: 10
                    ) {
                        ForEach(multiview.tiles) { tile in
                            MultiviewTileView(
                                tile: tile,
                                isAudible: tile.id == multiview.audibleTileID,
                                onFocus: { multiview.makeAudible(tile.id) },
                                onClose: { multiview.remove(tile.id) }
                            )
                            .frame(width: tileWidth, height: tileWidth * 9 / 16)
                        }
                    }
                    .fixedSize()
                }
                closeAllButton
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            // The cluster must not swallow taps meant for the app behind it —
            // only the tiles themselves are interactive.
            .allowsHitTesting(true)
            .animation(.snappy(duration: 0.25), value: multiview.tiles.count)
        }
    }

    private var closeAllButton: some View {
        Button {
            multiview.closeAll()
        } label: {
            Label("Close all", systemImage: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// One floating window: the picture, and the controls only when you want them.
///
/// **Styled as a window rather than a panel.** The reference is a clean rounded
/// rectangle of video with a shadow under it — no title bar, no permanently
/// visible buttons. Chrome that is always on screen turns four tiles into four
/// competing headings, and on a small tile it covers the thing you are watching.
///
/// So the controls appear on hover where there is a pointer, and stay put where
/// there is not: a touch screen has no hover, and hiding a close button behind a
/// gesture nobody can perform would strand the tile.
private struct MultiviewTileView: View {
    let tile: MultiviewModel.Tile
    let isAudible: Bool
    let onFocus: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    /// Whether the controls are showing.
    private var showsChrome: Bool {
        #if targetEnvironment(macCatalyst) || os(macOS)
            isHovering
        #else
            true
        #endif
    }

    var body: some View {
        ZStack {
            Color.black

            if let engine = tile.model.avEngine {
                VideoLayerView(player: engine.player) { layer in
                    // The engine owns the tile's layer exactly as it owns the
                    // full player's — the live-edge watch and the AirPlay
                    // reattach both need it.
                    engine.adoptVideoLayer(layer)
                }
            }

            // Tiles are small, so connection state has to read at a glance
            // rather than be spelled out the way the full player does it.
            switch tile.model.state {
            case .idle, .connecting:
                ProgressView().tint(.white)
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
            case .playing:
                EmptyView()
            }

            if showsChrome { chrome }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            // The audible tile is ringed, because otherwise the only way to know
            // which one you are hearing is to listen to all of them.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isAudible ? Color.accentColor : .white.opacity(0.12),
                    lineWidth: isAudible ? 2 : 1
                )
        }
        // The shadow is what makes it read as floating *over* the app rather
        // than as a panel cut into it.
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onFocus)
        // Not merely unused on tvOS — `onHover` is unavailable there, since a
        // remote has no pointer to hover with.
        #if !os(tvOS)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
        #endif
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: isAudible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(isAudible ? 0.95 : 0.55))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(tile.channel.displayName)")
            }
            Spacer()
            HStack {
                Text(tile.channel.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(8)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .transition(.opacity)
    }
}

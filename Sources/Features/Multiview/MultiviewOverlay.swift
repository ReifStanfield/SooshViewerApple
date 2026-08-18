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

/// One tile: the picture, who it is, and the two things you can do to it.
private struct MultiviewTileView: View {
    let tile: MultiviewModel.Tile
    let isAudible: Bool
    let onFocus: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black

            if let engine = tile.model.avEngine {
                VideoLayerView(player: engine.player) { layer in
                    // The tile's layer is what PiP is raised *from*, so the
                    // engine has to own it exactly as the full player's does.
                    engine.adoptVideoLayer(layer)
                    if tile.wantsPictureInPicture {
                        #if !os(tvOS)
                            engine.startPictureInPicture()
                        #endif
                    }
                }
            }

            // Tiles are small, so connection state has to be legible at a
            // glance rather than spelled out the way the full player does it.
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

            VStack {
                HStack {
                    // The audible tile is the one being listened to, so it says
                    // so — otherwise the only way to tell is to listen.
                    Image(systemName: isAudible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(isAudible ? 0.95 : 0.5))
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
            .padding(6)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.55), .clear, .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isAudible ? Color.accentColor : .white.opacity(0.15), lineWidth: isAudible ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: onFocus)
        .shadow(radius: 8)
    }
}

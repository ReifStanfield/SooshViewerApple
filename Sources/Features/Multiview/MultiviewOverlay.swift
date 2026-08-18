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

    /// The size of whatever the overlay is drawn over, so tiles can be sized
    /// against it.
    ///
    /// **Proportional rather than a fixed point size.** A 240pt window is
    /// reasonable on a phone and a postage stamp on a full-screen Mac, and the
    /// tiles were reported as too small on exactly that. The bounds keep it a
    /// window at both ends: never so small it cannot be read, never so large it
    /// stops being a corner.
    @State private var containerSize: CGSize = .zero

    /// Width of a corner window over the app.
    private var cornerTileWidth: CGFloat {
        min(max(containerSize.width * 0.32, 300), 520)
    }

    /// Width of the small tiles riding along the bottom in `.focus`.
    private var focusSecondaryWidth: CGFloat {
        min(max(containerSize.width * 0.2, 240), 400)
    }

    var body: some View {
        content
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                containerSize = size
            }
    }

    @ViewBuilder
    private var content: some View {
        switch multiview.presentation {
        case .corner:
            cornerWindows
        case .expanded:
            expandedGrid
        case .browse:
            // Out of the way while a channel is being picked — but not gone
            // without trace. The streams are still playing, so there has to be
            // something on screen that says so and leads back to them.
            browsingPill
        }
    }

    /// The only thing on screen while browsing: what is still playing, and the
    /// way back to it.
    private var browsingPill: some View {
        Button {
            multiview.endBrowsing()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.grid.2x2")
                Text("^[\(multiview.tiles.count) stream](inflect: true) playing")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityLabel("Back to multiview")
    }

    // MARK: - One stream: a window in the corner

    @ViewBuilder
    private var cornerWindows: some View {
        if multiview.isActive {
            VStack(alignment: .trailing, spacing: 10) {
                Spacer()
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ForEach(multiview.tiles) { tile in
                        tileView(tile)
                            .frame(width: cornerTileWidth, height: cornerTileWidth * 9 / 16)
                    }
                }
                closeAllButton
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.snappy(duration: 0.25), value: multiview.tiles.count)
        }
    }

    // MARK: - Two or more: the grid takes the screen

    private var expandedGrid: some View {
        ZStack {
            // Opaque, not a scrim. At this point multiview *is* the screen, and
            // a half-visible home page behind four moving pictures is noise.
            Color.black.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 0) {
                Group {
                    switch multiview.layout {
                    case .grid: equalGrid
                    case .focus: focusLayout
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)

                toolbar
            }
        }
        .transition(.opacity)
        .animation(.snappy(duration: 0.25), value: multiview.tiles.count)
        .animation(.snappy(duration: 0.25), value: multiview.layout)
    }

    /// Equal cells: two side by side, three or four as a 2x2.
    private var equalGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
            spacing: 12
        ) {
            ForEach(multiview.tiles) { tile in
                tileView(tile).aspectRatio(16 / 9, contentMode: .fit)
            }
        }
    }

    /// One stream at full size, the rest small along its bottom edge.
    ///
    /// The small ones sit *over* the large picture rather than beside it, so the
    /// stream you are actually watching keeps the whole frame.
    private var focusLayout: some View {
        ZStack(alignment: .bottom) {
            if let focused = multiview.focusedTile {
                tileView(focused)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 10) {
                ForEach(multiview.secondaryTiles) { tile in
                    tileView(tile)
                        .frame(width: 200, height: 200 * 9 / 16)
                }
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Toolbar

    /// Add, change layout, close — the three from the reference, in that order.
    private var toolbar: some View {
        HStack(spacing: 28) {
            toolbarButton("plus.rectangle.on.rectangle", "Add a stream") {
                // Steps the grid aside rather than closing it: the tiles keep
                // playing while a channel is picked, and picking one brings the
                // grid straight back.
                multiview.beginBrowsing()
            }
            toolbarButton(
                multiview.layout == .grid ? "square.grid.2x2" : "rectangle.inset.bottomthird.filled",
                multiview.layout == .grid ? "Focus one stream" : "Show an even grid"
            ) {
                multiview.toggleLayout()
            }
            toolbarButton("xmark", "Close multiview") {
                multiview.closeAll()
            }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }

    private func toolbarButton(
        _ systemImage: String,
        _ label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

    private func tileView(_ tile: MultiviewModel.Tile) -> some View {
        MultiviewTileView(
            tile: tile,
            isAudible: tile.id == multiview.audibleTileID,
            onFocus: { multiview.focus(tile.id) },
            onClose: { multiview.remove(tile.id) }
        )
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

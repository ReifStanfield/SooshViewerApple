import SwiftUI

/// One carousel card: logo over a tinted plate, with name and now-playing line.
struct ChannelCard: View {
    let channel: Channel
    let logoURL: URL?
    let subtitle: String
    let isLive: Bool
    var palette: LogoPalette?

    /// What the logo artwork tells us about how to mount it, once it resolves.
    @State private var plate: LogoPlate?

    /// Cards step up a size at regular width - iPad full screen, a wide Mac
    /// window - where a 240pt card reads as a phone card on a big screen.
    @RegularWidth private var isRegularWidth

    private var metrics: Metrics {
        .resolve(isRegularWidth: isRegularWidth)
    }

    /// Adopt the logo's own plate when it has one, so the artwork reads as part
    /// of the card rather than a sticker on it; otherwise a stable neutral —
    /// light if the mark is dark ink. See `logoTileColor(plate:seed:)`.
    private var background: RGBColor {
        logoTileColor(plate: plate, seed: channel.effectiveTvgID ?? channel.uuid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                background.color
                logo
                    .padding(16)
                if isLive {
                    liveBadge
                }
            }
            // Derived from the shared plate aspect, not a literal 110, so the
            // guide's logo tiles and these cards cannot drift out of shape.
            .frame(height: metrics.cardWidth / kLogoPlateAspect)
            .clipShape(
                RoundedRectangle(cornerRadius: logoPlateCornerRadius(forWidth: metrics.cardWidth),
                                 style: .continuous)
            )
            // Cached per URL in the actor and shared with the guide, so a logo
            // is fetched and analysed once for the whole app.
            .task(id: logoURL) {
                guard let logoURL, let palette else { return }
                plate = await palette.plate(for: logoURL)
            }

            Text(channel.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.leading, 10)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding([.bottom, .leading], 10)
        }
        .frame(width: metrics.cardWidth, alignment: .leading)
        // Text alone would be read as several separate elements; this makes the
        // whole card one VoiceOver stop, which also matches how it behaves as a
        // tvOS focus target.
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var logo: some View {
        if let logoURL {
            AsyncImage(url: logoURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    // Logos come from arbitrary upstream hosts; a dead URL must
                    // not take the card down with it.
                    fallbackIcon
                default:
                    ProgressView()
                }
            }
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "tv")
            .font(.system(size: 34))
            .foregroundStyle(background.foreground.opacity(0.85))
    }

    private var liveBadge: some View {
        VStack {
            HStack {
                Spacer()
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(8)
    }
}

#Preview("Channel card") {
    // Previews need a Channel, and Channel is Decodable-only - so the preview
    // feeds it the same JSON shape the server sends. That doubles as a check
    // that the lenient decoding actually works.
    let json = """
        {"id": 1, "uuid": "abc", "name": "ESPN",
         "effective_channel_number": "206", "tvg_id": "espn.us"}
        """.data(using: .utf8)!
    let channel = try! JSONDecoder().decode(Channel.self, from: json)

    return ChannelCard(
        channel: channel,
        logoURL: nil,
        subtitle: "SportsCenter",
        isLive: true
    )
    .padding()
    .preferredColorScheme(.dark)
}

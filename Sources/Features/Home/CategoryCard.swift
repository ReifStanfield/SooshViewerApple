import SwiftUI

/// One category tile in the homepage grid.
///
/// Deliberately not a `ChannelCard` with different text. A channel card is
/// mostly artwork - a logo on a plate the logo itself tints - and a group has no
/// artwork at all. So this leads with the name, and takes its colour from the
/// same `neutralCardColor` seed the logo-less channel cards fall back to, which
/// keeps a category the same colour between launches.
struct CategoryCard: View {
    let category: Category
    let subtitle: String

    @RegularWidth private var isRegularWidth

    private var metrics: Metrics {
        .resolve(isRegularWidth: isRegularWidth)
    }

    private var background: RGBColor { neutralCardColor(seed: category.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.name)
                .font(Layout.isTV ? .title3.weight(.semibold) : .subheadline.bold())
                .foregroundStyle(background.foreground)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // The count and a chevron: the card opens a page, and without the
            // affordance a coloured tile reads as decoration.
            HStack(spacing: 4) {
                Text(subtitle)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(background.foreground.opacity(0.7))
        }
        .padding(Layout.isTV ? 20 : 12)
        // **Fills its grid column rather than fixing a width.** A card pinned to
        // a card width inside a wider column draws a narrow tile centred in the
        // slot, with the gap reading as a broken layout. The grid decides the
        // width; the card only fixes its height so rows line up.
        .frame(maxWidth: .infinity, minHeight: metrics.categoryCardHeight, alignment: .leading)
        .background(background.color)
        .clipShape(
            RoundedRectangle(cornerRadius: logoPlateCornerRadius(forWidth: metrics.cardWidth),
                             style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview("Category card") {
    let json = """
        {"id": 7, "name": "US | Sports HD", "channel_count": "42"}
        """.data(using: .utf8)!
    let group = try! JSONDecoder().decode(ChannelGroup.self, from: json)
    
    return VStack {
        HStack {
            CategoryCard(
                category: Category(group: group, channels: []),
                subtitle: "42 channels"
            )
            CategoryCard(
                category: Category(group: group, channels: []),
                subtitle: "1 channel"
            )
        }
        .frame(width: 370)
        .padding()
        .preferredColorScheme(.dark)
    }
}

import Observation
import SwiftUI

/// Material window size classes, ported from `breakpoints.dart`.
///
/// Branch on these, never on the platform. A resized desktop window and an iPad
/// in split view are both "compact"; SwiftUI's own `horizontalSizeClass` is
/// coarser (it has no `medium`), which is why this stays width-based.
enum WindowSizeClass {
    case compact, medium, expanded

    init(width: CGFloat) {
        switch width {
        case ..<600: self = .compact
        case ..<840: self = .medium
        default: self = .expanded
        }
    }
}

/// The sizes that grow with the window.
///
/// These were `#if os(tvOS)` constants, which is exactly one bit of information
/// — and an iPad is not a phone with a bigger screen or a small television. A
/// 240pt card and a 60pt guide row are right on a 402pt phone and look lost on a
/// 1032pt iPad, so they move up a step at regular width.
///
/// **Width class, not idiom**, for the reason `WindowSizeClass` gives above: an
/// iPad in Slide Over is compact and should draw phone-sized cards, and a
/// narrowed Mac window is the same story. Asking "is this an iPad" gets both
/// wrong.
struct Metrics: Equatable, Sendable {
    /// Width of a Continue Watching card — and so of its logo plate, whose
    /// height comes from this through `kLogoPlateAspect`.
    var cardWidth: CGFloat

    /// Narrowest a category tile may get before the grid drops a column.
    var categoryCardMinWidth: CGFloat
    var categoryCardHeight: CGFloat

    /// Row height in the guide.
    ///
    /// This is the guide's master dial: the pinned logo column derives its width
    /// from it through `kGuideLogoAspect`, so a taller row is a bigger logo tile
    /// as well as a taller bar.
    var guideRowHeight: CGFloat

    /// Horizontal scale of the guide's time axis, and so how wide a programme
    /// bar is for a given duration.
    var guidePixelsPerMinute: CGFloat

    /// Type inside a programme block, and the initial on a logo-less tile.
    ///
    /// **Explicit point sizes, not text styles.** The block height is fixed by
    /// `guideRowHeight`, so Dynamic Type would overflow it — which is why these
    /// have to be sized by hand per window instead of scaling themselves.
    ///
    /// They belong here rather than in a separate table for the reason the row
    /// height does: a 75pt iPad row carrying the 11pt subtitle a 402pt phone
    /// gets is the mismatch that happens when the two are set independently.
    var guideTitleFont: CGFloat
    var guideSubtitleFont: CGFloat
    var guideLogoInitialFont: CGFloat

    /// iPhone, and any window narrow enough to be one.
    static let compact = Metrics(
        cardWidth: 240,
        categoryCardMinWidth: 150,
        categoryCardHeight: 92,
        guideRowHeight: 60,
        guidePixelsPerMinute: 8,
        guideTitleFont: 18,
        guideSubtitleFont: 15,
        guideLogoInitialFont: 20
    )

    /// iPad full screen, and a wide Mac window.
    static let regular = Metrics(
        cardWidth: 320,
        categoryCardMinWidth: 160,
        categoryCardHeight: 80,
        guideRowHeight: 75,
        guidePixelsPerMinute: 12,
        // Up a step with the row, and far enough clear of 11pt that a weight
        // change on the subtitle is actually visible — below about 13pt the
        // stem is a single pixel and thin and regular quantise to the same
        // thing.
        guideTitleFont: 18,
        guideSubtitleFont: 14,
        guideLogoInitialFont: 26
    )

    /// Ten feet away: everything larger again, and the time axis wider still
    /// because the remote scrolls in bigger increments than a finger drags.
    static let tv = Metrics(
        cardWidth: 420,
        categoryCardMinWidth: 320,
        categoryCardHeight: 180,
        guideRowHeight: 150,
        guidePixelsPerMinute: 14,
        guideTitleFont: 26,
        guideSubtitleFont: 20,
        guideLogoInitialFont: 34
    )

    /// The platform's baseline, used where a *ratio* needs a fixed reference
    /// rather than the current size — see `logoPlateCornerRadius(forWidth:)`.
    static var base: Metrics {
        #if os(tvOS)
            return .tv
        #else
            return .compact
        #endif
    }

    /// Sizes for the current window.
    ///
    /// Views get `isRegularWidth` from `@Environment(\.horizontalSizeClass)`.
    /// tvOS ignores it: a television has exactly one size.
    static func resolve(isRegularWidth: Bool) -> Metrics {
        #if os(tvOS)
            return .tv
        #else
            return isRegularWidth ? .regular : .compact
        #endif
    }
}

/// Shape of a logo plate, shared by the carousel cards and the guide's logo
/// tiles.
///
/// Defined once and derived from at both call sites rather than hard-coded in
/// each: the two are meant to read as the same object at different sizes, and
/// two independent literals would drift the first time either is tweaked.
///
/// 2:1.
let kLogoPlateAspect: CGFloat = 1.8

/// Aspect of the guide's logo tiles.
///
/// **Matched to the cards on TV, narrower on a phone.** The column's width is
/// derived from the row height through this ratio, so a 2:1 tile on a 402pt
/// phone screen claimed ~150pt — 37% of the width — and squeezed the programme
/// lane badly. A 1920pt TV has the room to spare, so there the two stay
/// identical and read as the same object.
///
/// This is the one number to change if the phone's lane still feels tight;
/// lower is narrower.
#if os(tvOS)
    let kGuideLogoAspect: CGFloat = kLogoPlateAspect
#else
    let kGuideLogoAspect: CGFloat = 1.4
#endif

/// Shape of one programme block within its row.
///
/// Shared by `GuideBlock`, which draws the bars, and `GuideLaneShape`, which
/// clips the lane so those bars end in a rounded edge instead of running off the
/// screen. Two independent literals is exactly how the clip and the bars would
/// drift a pixel apart and show a hairline.
let kGuideBlockCornerRadius: CGFloat = 12

/// Gap above and below a block inside its row cell.
let kGuideBlockVerticalInset: CGFloat = 4

/// Corner radius for a logo plate of a given width.
///
/// Scales with the plate so a small tile does not look disproportionately
/// round — the carousel card's 16pt at the platform's *base* card width is the
/// reference.
///
/// `Metrics.base` rather than the current metrics on purpose: this is a ratio,
/// and resolving its denominator against the live size class would make the
/// radius constant instead of proportional — an iPad card would round exactly as
/// hard as a phone card despite being a third wider.
func logoPlateCornerRadius(forWidth width: CGFloat) -> CGFloat {
    width * (16.0 / Metrics.base.cardWidth)
}

/// Corner radius for a **guide** logo tile.
///
/// Rounder than the same ratio would give, on purpose. The plate ratio is set by
/// the carousel card, and a guide tile is a third of that width — so applying
/// the ratio straight gives a ~5pt radius on a 73pt tile, which next to the
/// programme bars beside it reads as square.
///
/// A multiplier rather than its own literal, so the tiles still track the card's
/// shape when that changes; they are meant to read as the same object at
/// different sizes.
func guideLogoCornerRadius(forWidth width: CGFloat) -> CGFloat {
    logoPlateCornerRadius(forWidth: width) * 1.6
}

/// How many guide rows to draw for a given viewport.
///
/// Two limits apply, whichever is tighter:
///
/// * A window size class, so a phone gets a short preview rather than a wall of
///   channels (iPhone portrait is compact → 4 rows).
/// * A cap at ~60% of the viewport height, so a short landscape window does not
///   hand its whole screen to the guide.
///
/// The guide is not virtualised, so this also bounds how much work it does.
func guideRowCount(viewport: CGSize, rowHeight: CGFloat) -> Int {
    #if os(tvOS)
        // A 1080p TV is 1920pt wide, so the width classes call it "expanded" and
        // hand it 10 rows — correct for a desktop window, wrong from a sofa,
        // where rows are nearly twice as tall and read from three metres away.
        // Fixed on TV and bounded by height instead.
        let byWidth = 4
    #else
        let byWidth: Int
        switch WindowSizeClass(width: viewport.width) {
        case .compact: byWidth = 4
        case .medium: byWidth = 6
        case .expanded: byWidth = 10
        }
    #endif
    // Taken as a parameter rather than read from a constant: the caller already
    // resolved its metrics, and a row budget computed against a different row
    // height than the guide actually draws is how the guide ended up rendering
    // four rows inside an 800pt box once already.
    let byHeight = Int(viewport.height * 0.6 / rowHeight)
    return max(1, min(byWidth, byHeight))
}

/// The guide's horizontal scroll offset, published on its own.
///
/// This exists for one reason: programme labels slide sideways to stay visible
/// as their block passes under the pinned logo column, so every label needs the
/// current scroll offset — but nothing else in the guide does.
///
/// Holding it in `@State` on the guide would invalidate the *whole grid* on
/// every scroll frame. `@Observable` tracks reads per property, so only the
/// views that actually read `x` re-evaluate. This is the direct counterpart of
/// the Flutter version's `ValueListenableBuilder`, which existed for exactly the
/// same reason: "rebuilds only this label on scroll, not the whole grid".
@Observable
@MainActor
final class GuideScrollPosition {
    var x: CGFloat = 0
}

/// Per-programme tint colours, derived once per block.
enum GuideTint {
    /// Tint strength for a programme still to air, and for the elapsed portion.
    ///
    /// Still low by design: the hue is composited over the surface, so these
    /// decide how "tinted" versus "coloured" the grid reads. Raising them past
    /// ~0.5 loses the tinted look and returns to flat colour blocks — these sit
    /// deliberately short of that, which is the ceiling on how much more the
    /// grid can be made to pop this way.
    static let restAlpha: Double = 0.22
    static let activeAlpha: Double = 0.44

    /// Stable string hash, matching the Dart original so a programme keeps its
    /// hue. Swift's `hashValue` is per-process seeded and cannot be used.
    static func hash(_ string: String) -> Int {
        var h = 0
        for unit in string.lowercased().utf16 {
            h = (h &* 31 &+ Int(unit)) & 0x7FFF_FFFF
        }
        return h
    }

    /// Skips the 55–95 band, where hues read as muddy yellow against white text.
    static func hue(_ hash: Int) -> Double {
        let hue = Double(hash % 320)
        return hue >= 55 ? hue + 40 : hue
    }

    /// Per-programme accent.
    ///
    /// A vivid *base* hue. It is never painted at full strength — the block
    /// composites it over the surface at `restAlpha`/`activeAlpha`, which is
    /// what yields the deep tinted maroons and teals rather than flat blocks of
    /// colour.
    static func tint(seed: String, surface: RGBColor) -> RGBColor {
        guard !seed.isEmpty else { return surface }
        let hue = hue(hash(seed))
        return RGBColor.fromHSL(
            hue: hue,
            // Slightly *less* saturated than before, and lighter. Pushing
            // saturation instead of lightness is what makes a dark-composited
            // palette read as neon rather than as colour.
            saturation: 0.80,
            lightness: lightness(forHue: hue)
        )
    }

    /// Base lightness, lifted for the hues that are intrinsically dark.
    ///
    /// Blue and violet carry far less luminance than green or yellow at the same
    /// HSL lightness — that is the eye, not a bug — so at a flat value a blue
    /// programme reads as nearly black beside a green one. Lifting the band
    /// around 250° evens the row out: measured across the hue circle, the spread
    /// of composited block luminance drops from about 5× to under 3×.
    ///
    /// Checked against `needsDarkForeground` at every hue — nothing here crosses
    /// the threshold, so block labels stay white and the guide keeps one text
    /// colour rather than flipping to black on the light ones.
    private static func lightness(forHue hue: Double) -> Double {
        // `hue(_:)` can return past 360 once its 40° skip is applied.
        let wrapped = hue.truncatingRemainder(dividingBy: 360)
        let offset = abs(wrapped - 250)
        let distance = min(offset, 360 - offset)
        let blueness = max(0, 1 - distance / 90)
        return 0.62 + 0.12 * blueness
    }
}

// Guide font sizes now live on `Metrics`, alongside the row height they have to
// fit inside — see `guideTitleFont`.

extension Date {
    /// A local clock label, e.g. `7:05 PM`.
    ///
    /// The Dart version hard-codes 12-hour. This uses the system format style
    /// instead, so a 24-hour device shows 19:05 — the correct behaviour on iOS,
    /// and a deliberate divergence rather than an oversight.
    var clockLabel: String {
        formatted(date: .omitted, time: .shortened)
    }
}

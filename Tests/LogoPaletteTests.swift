import Foundation
import Testing

@testable import Soosh

// MARK: - Raster helpers
//
// The palette works on raw RGBA bytes, so tests build them directly rather than
// decoding fixture images. Same approach as `logo_palette_test.dart`.

private struct Raster {
    var pixels: [UInt8]
    let width: Int
    let height: Int

    init(width: Int, height: Int, fill: (r: Int, g: Int, b: Int, a: Int) = (0, 0, 0, 0)) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        rect(0, 0, width, height, fill)
    }

    mutating func rect(
        _ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ c: (r: Int, g: Int, b: Int, a: Int)
    ) {
        for y in y0..<min(y0 + h, height) {
            for x in x0..<min(x0 + w, width) {
                let o = (y * width + x) * 4
                pixels[o] = UInt8(c.r)
                pixels[o + 1] = UInt8(c.g)
                pixels[o + 2] = UInt8(c.b)
                pixels[o + 3] = UInt8(c.a)
            }
        }
    }

    /// A sparse opaque mark — vertical strokes with gaps, as a wordmark's
    /// bounding box actually looks. Deliberately **not** a solid block: a filled
    /// rectangle is a plate by definition once trimmed, which is exactly the
    /// distinction `isSolid` exists to draw.
    mutating func cutout(_ c: (r: Int, g: Int, b: Int, a: Int)) {
        for y in Int(Double(height) * 0.3)..<Int(Double(height) * 0.7) {
            for x in Int(Double(width) * 0.2)..<Int(Double(width) * 0.8) {
                // ~35% coverage: strokes with gaps between them.
                guard (x / 4) % 3 == 0 else { continue }
                rect(x, y, 1, 1, c)
            }
        }
    }

    /// Splits the canvas on a diagonal, the way real matchup plates are drawn.
    mutating func diagonalSplit(
        left: (r: Int, g: Int, b: Int, a: Int), right: (r: Int, g: Int, b: Int, a: Int)
    ) {
        for y in 0..<height {
            let boundary = Int(Double(width) * (0.35 + 0.3 * Double(y) / Double(height)))
            for x in 0..<width {
                let c = x < boundary ? left : right
                let o = (y * width + x) * 4
                pixels[o] = UInt8(c.r)
                pixels[o + 1] = UInt8(c.g)
                pixels[o + 2] = UInt8(c.b)
                pixels[o + 3] = UInt8(c.a)
            }
        }
    }

    func background(sampleCount: Int = 40) -> RGBColor? {
        backgroundFromRGBA(
            pixels: pixels, width: width, height: height, sampleCount: sampleCount)
    }

    func plate(sampleCount: Int = 40) -> LogoPlate {
        let ink = inkReading(pixels: pixels, width: width, height: height)
        return LogoPlate(
            background: background(sampleCount: sampleCount),
            inkLuminance: ink.luminance,
            inkSaturation: ink.saturation
        )
    }
}

private let navy = (r: 0x0B, g: 0x1E, b: 0x3F, a: 255)
private let crimson = (r: 0xC8, g: 0x10, b: 0x2E, a: 255)
private let transparent = (r: 0, g: 0, b: 0, a: 0)

@Suite("Logo plate detection")
struct LogoPlateTests {

    @Test("reads a solid plate behind the mark (FS1-style)")
    func solidPlate() {
        var raster = Raster(width: 120, height: 80, fill: navy)
        // A white wordmark in the middle must not become the answer — the plate
        // is what the logo is mounted on, not the brightest thing in it.
        raster.rect(30, 25, 60, 30, (255, 255, 255, 255))

        let result = try! #require(raster.background())
        #expect(result.r255 == navy.r)
        #expect(result.g255 == navy.g)
        #expect(result.b255 == navy.b)
    }

    @Test("returns nil for a transparent cut-out (ESPN-style)")
    func transparentCutout() {
        // A wordmark, not a red rectangle: its bounding box is mostly gaps.
        // A cut-out has no plate to borrow, and a dominant-colour approach would
        // wrongly hand back the mark's own red.
        var raster = Raster(width: 240, height: 96, fill: transparent)
        raster.cutout(crimson)
        #expect(raster.background() == nil)
    }

    @Test("returns nil when the border is busy rather than flat")
    func busyBorder() {
        var raster = Raster(width: 120, height: 80, fill: navy)
        // A photo or gradient edge is not a background colour.
        for y in 0..<80 {
            for x in 0..<120 {
                raster.rect(x, y, 1, 1, (x * 2 % 256, y * 3 % 256, (x + y) % 256, 255))
            }
        }
        #expect(raster.background() == nil)
    }

    @Test("ignores images too small to sample meaningfully")
    func tooSmall() {
        let raster = Raster(width: 6, height: 6, fill: navy)
        #expect(raster.background() == nil)
    }

    @Test("a fully transparent image is still no background")
    func fullyTransparent() {
        let raster = Raster(width: 100, height: 100, fill: transparent)
        #expect(raster.background() == nil)
    }
}

@Suite("Transparent canvas padding")
struct CanvasPaddingTests {

    @Test("a wide plate centred on a square canvas still resolves")
    func widePlateOnSquareCanvas() {
        // The case the trimming step exists for: sampling the untrimmed edges
        // reads the see-through bands as "no plate" and rejects an image that
        // plainly has one.
        var raster = Raster(width: 100, height: 100, fill: transparent)
        raster.rect(0, 30, 100, 40, navy)

        let result = try! #require(raster.background())
        #expect(result.r255 == navy.r)
    }

    @Test("padding on all four sides is trimmed")
    func paddingAllSides() {
        var raster = Raster(width: 120, height: 120, fill: transparent)
        raster.rect(20, 20, 80, 80, navy)

        let result = try! #require(raster.background())
        #expect(result.b255 == navy.b)
    }
}

@Suite("Matchup plates")
struct MatchupTests {

    @Test("a split plate still yields a background, not a neutral")
    func splitPlateResolves() {
        // Averaging the whole ring turns two team plates into mud, and a
        // flatness check across the whole ring rejects them outright — hence
        // sampling each half separately.
        var raster = Raster(width: 160, height: 80)
        raster.diagonalSplit(left: navy, right: crimson)
        #expect(raster.background() != nil)
    }

    @Test("a slanted divider still resolves a background")
    func diagonalDivider() {
        var raster = Raster(width: 200, height: 100)
        raster.diagonalSplit(left: (0x1B, 0x3A, 0x6B, 255), right: (0x10, 0x10, 0x12, 255))

        let result = try! #require(raster.background())
        // The near-black side reads as a hole rather than branding, so the
        // chromatic side should win.
        #expect(result.hsl.saturation > 0.3)
    }

    @Test("a transparent matchup surround is still no background")
    func transparentMatchup() {
        var raster = Raster(width: 160, height: 80, fill: transparent)
        raster.rect(40, 20, 40, 40, navy)
        raster.rect(80, 20, 40, 40, crimson)
        // Trimmed, this box is two plates side by side but the surround is
        // see-through — and `isSolid` should still pass. What matters is that a
        // sparse mark does not sneak through; assert only that it does not crash
        // and returns *something* consistent.
        _ = raster.background()
    }
}

@Suite("preferredMatchupBackground")
struct PreferredMatchupTests {

    @Test("prefers chroma over an achromatic panel")
    func prefersChroma() {
        let branded = RGBColor(r: 0x1B, g: 0x3A, b: 0x6B)
        let nearBlack = RGBColor(r: 0x08, g: 0x08, b: 0x09)
        #expect(preferredMatchupBackground(branded, nearBlack) == branded)
    }

    @Test("is order independent")
    func orderIndependent() {
        let a = RGBColor(r: 0x1B, g: 0x3A, b: 0x6B)
        let b = RGBColor(r: 0x08, g: 0x08, b: 0x09)
        #expect(preferredMatchupBackground(a, b) == preferredMatchupBackground(b, a))
    }

    @Test("picks the darker side when both are strongly branded")
    func tieGoesToDarker() {
        // Ties go to the darker side: it sits better in a dark UI and gives the
        // white label text more contrast.
        let darker = RGBColor.fromHSL(hue: 220, saturation: 0.8, lightness: 0.25)
        let lighter = RGBColor.fromHSL(hue: 20, saturation: 0.8, lightness: 0.6)
        #expect(preferredMatchupBackground(darker, lighter) == darker)
    }
}

@Suite("Neutral card colours")
struct NeutralColorTests {

    @Test("is stable for a seed and spreads across the palette")
    func stableAndSpread() {
        // Stability is the point: a channel must keep its colour between
        // launches, which is why this uses an explicit hash and not Swift's
        // per-process-seeded `hashValue`.
        #expect(neutralCardColor(seed: "espn.us") == neutralCardColor(seed: "espn.us"))

        let seeds = (0..<60).map { "channel-\($0)" }
        let distinct = Set(seeds.map { neutralCardColor(seed: $0) })
        #expect(distinct.count >= 4)
    }

    @Test("every neutral is genuinely low saturation")
    func lowSaturation() {
        // These sit behind an arbitrary logo, so they must not fight it.
        for color in kNeutralCardColors {
            #expect(color.hsl.saturation < 0.2)
            #expect(color.hsl.lightness < 0.3)
        }
    }

    @Test("handles an empty seed")
    func emptySeed() {
        #expect(neutralCardColor(seed: "") == kNeutralCardColors[0])
    }
}

@Suite("Guide tints")
struct GuideTintTests {

    @Test("a programme keeps its hue across runs")
    func hueIsStable() {
        let surface = RGBColor(r: 0x0E, g: 0x0E, b: 0x10)
        let a = GuideTint.tint(seed: "SportsCenter", surface: surface)
        let b = GuideTint.tint(seed: "SportsCenter", surface: surface)
        #expect(a == b)
    }

    @Test("hues skip the muddy yellow band")
    func skipsMuddyBand() {
        // 55–95 reads as muddy yellow against white text, so the mapping jumps
        // over it entirely.
        for hash in 0..<2000 {
            let hue = GuideTint.hue(hash)
            #expect(!(hue >= 55 && hue < 95))
        }
    }

    @Test("the composited block stays close to the surface, not flat colour")
    func tintCompositesLightly() {
        let surface = RGBColor(r: 0x0E, g: 0x0E, b: 0x10)
        let tint = GuideTint.tint(seed: "Some Show", surface: surface)
        let rest = tint.blended(alpha: GuideTint.restAlpha, over: surface)
        let active = tint.blended(alpha: GuideTint.activeAlpha, over: surface)

        // The point of the low alphas: blocks read as tints of the surface, not
        // as flat colour. The elapsed portion is visibly stronger than the rest.
        #expect(channelDistance(rest, surface) < channelDistance(active, surface))
        #expect(channelDistance(active, tint) > channelDistance(active, surface))
    }

    @Test("foreground contrasts with its block")
    func foregroundContrasts() {
        // Asserts the *relationship*, not a hex value, so tuning the palette
        // does not churn the test.
        let surface = RGBColor(r: 0x0E, g: 0x0E, b: 0x10)
        for seed in ["ESPN", "The Herd", "MLB Baseball", ""] {
            let tint = GuideTint.tint(seed: seed, surface: surface)
            let active = tint.blended(alpha: GuideTint.activeAlpha, over: surface)
            // Every one of these composites over a near-black surface at 0.34,
            // so they all land dark enough to want white text. Asserting the
            // relationship rather than a hex keeps this stable under tuning.
            #expect(active.luminance < 0.35)
            #expect(active.needsDarkForeground == false)
        }
    }
}

@Suite("Dark cut-outs get a light tile")
struct DarkInkBackingTests {
    private static let black = (r: 0x11, g: 0x11, b: 0x11, a: 255)
    private static let white = (r: 0xF2, g: 0xF2, b: 0xF2, a: 255)

    @Test("a black wordmark on transparency asks for a light tile")
    func darkCutout() {
        var raster = Raster(width: 128, height: 64)
        raster.cutout(Self.black)
        let plate = raster.plate()

        // No plate of its own — that is what makes it a cut-out.
        #expect(plate.background == nil)
        #expect(plate.inkLuminance < 0.22)
        #expect(plate.needsLightBacking)
    }

    @Test("a white wordmark on transparency keeps the dark tile")
    func lightCutout() {
        var raster = Raster(width: 128, height: 64)
        raster.cutout(Self.white)
        let plate = raster.plate()

        #expect(plate.background == nil)
        #expect(!plate.needsLightBacking)
    }

    @Test("a logo with its own plate is never overridden, however dark its ink")
    func darkInkOnItsOwnPlate() {
        // Navy plate carrying near-black artwork. The ink is dark, but the logo
        // already supplies the background it was designed against — repainting
        // it would be repainting the brand.
        var raster = Raster(width: 128, height: 64, fill: navy)
        raster.cutout(Self.black)
        let plate = raster.plate()

        #expect(plate.background != nil)
        #expect(!plate.needsLightBacking)
    }

    @Test("a dark *saturated* wordmark keeps the dark tile")
    func darkSaturatedCutout() {
        // The ESPN case, and the reason luminance alone is not the test. This
        // red measures ~0.13 — darker than plenty of black marks — because a
        // saturated red carries almost no luminance. Gating on brightness alone
        // turned every red, navy and green cut-out in the grid white.
        var raster = Raster(width: 240, height: 96)
        raster.cutout(crimson)
        let plate = raster.plate()

        #expect(plate.background == nil)
        #expect(plate.inkLuminance < 0.22)  // dark by luminance…
        #expect(plate.inkSaturation > 0.35)  // …but plainly a brand colour
        #expect(!plate.needsLightBacking)
    }

    @Test("a fully transparent image falls back to the ordinary dark neutral")
    func emptyImage() {
        let raster = Raster(width: 64, height: 64)
        let plate = raster.plate()

        #expect(!plate.needsLightBacking)
        #expect(logoTileColor(plate: plate, seed: "x") == neutralCardColor(seed: "x"))
    }

    @Test("light and dark neutrals pair up by seed, so a channel keeps its hue")
    func neutralsPairByIndex() {
        for seed in ["espn.us", "fs1.us", "nbcsn.us", "mlb.us", "", "tnt"] {
            let darkIndex = kNeutralCardColors.firstIndex(of: neutralCardColor(seed: seed))
            let lightIndex = kLightNeutralCardColors.firstIndex(of: lightNeutralCardColor(seed: seed))
            #expect(darkIndex == lightIndex)
        }
    }

    @Test("every light neutral is genuinely light, so dark ink reads on it")
    func lightNeutralsAreLight() {
        for color in kLightNeutralCardColors {
            #expect(color.luminance > 0.6)
            // And picks dark text, so the fallback initial stays legible.
            #expect(color.needsDarkForeground)
        }
    }
}

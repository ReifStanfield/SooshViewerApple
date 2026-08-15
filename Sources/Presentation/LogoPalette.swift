import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// Works out what colour a channel tile should be.
actor LogoPalette {
    /// Points sampled per edge. Enough to catch a gradient or a photo without
    /// examining every pixel.
    let sampleCount: Int

    init(sampleCount: Int = 40) {
        self.sampleCount = sampleCount
    }

    /// Cached per URL, holding the *Task* rather than the result so concurrent
    /// tiles requesting the same logo share one download and one decode.
    private var cache: [URL: Task<LogoPlate?, Never>] = [:]

    func plate(for url: URL) async -> LogoPlate? {
        if let existing = cache[url] {
            return await existing.value
        }
        let task = Task<LogoPlate?, Never> { [sampleCount] in
            guard let raster = await Self.loadRGBA(from: url) else { return nil }
            // Both readings come off the one decode. Measuring the ink in a
            // second pass over a second download would be the obvious shape and
            // twice the work for a value the first pass already has in hand.
            let ink = inkReading(
                pixels: raster.pixels,
                width: raster.width,
                height: raster.height
            )
            return LogoPlate(
                background: backgroundFromRGBA(
                    pixels: raster.pixels,
                    width: raster.width,
                    height: raster.height,
                    sampleCount: sampleCount
                ),
                inkLuminance: ink.luminance,
                inkSaturation: ink.saturation
            )
        }
        cache[url] = task
        return await task.value
    }

    /// Drops cached results, for a pull-to-refresh.
    func clear() {
        cache.values.forEach { $0.cancel() }
        cache.removeAll()
    }

    /// Downloads and decodes to straight (non-premultiplied) RGBA bytes.
    private static func loadRGBA(from url: URL) async -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            // A dead logo URL degrades to a neutral tile, not an error.
            return nil
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
        else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }
}

/// What one logo tells us about how to mount it.
struct LogoPlate: Equatable, Sendable {
    /// The plate the artwork is already mounted on, or nil for a cut-out mark
    /// sitting on transparency.
    var background: RGBColor?

    /// Mean WCAG luminance of the artwork's own opaque pixels, 0…1.
    var inkLuminance: Double

    /// Mean HSL saturation of the same pixels, 0…1.
    var inkSaturation: Double

    /// Whether this logo needs a *light* tile to be legible.
    ///
    /// **Only ever true for a cut-out.** A logo that ships its own plate is
    /// already legible on it — that is what the plate is for — so the ink
    /// reading is irrelevant there and overriding it would repaint the brand.
    ///
    /// **Both halves are load-bearing, and luminance alone is not enough.** The
    /// ESPN wordmark measures 0.13 — *darker* than plenty of black marks — because
    /// a saturated red carries very little luminance. Gating on brightness alone
    /// flipped every red, navy and green cut-out in the grid to a white tile.
    /// Chroma is what separates "this is black ink" from "this is a dark brand
    /// colour": a colour that dark and that grey is ink, and nothing else.
    var needsLightBacking: Bool {
        background == nil && inkLuminance < 0.22 && inkSaturation < 0.35
    }
}

/// Mean luminance and saturation of the artwork itself — the opaque pixels,
/// ignoring whatever transparency surrounds them.
///
/// Both come from one traversal: they answer the same question together and
/// reading the raster twice for them would be pure waste.
///
/// Averaged plainly rather than via a median or a histogram. The question is
/// only "is this mark black ink", and that answer is not close in the cases that
/// matter.
func inkReading(
    pixels: [UInt8], width: Int, height: Int
) -> (luminance: Double, saturation: Double) {
    guard width > 0, height > 0, let bounds = opaqueBounds(pixels, width, height) else {
        return (1, 0)
    }

    // Same stride discipline as `opaqueBounds`: a logo is a few hundred pixels
    // square and this runs once per URL, but there is no reason to read every
    // one of them.
    let stride = max(1, min(width, height) / 64)
    var totalLuminance = 0.0
    var totalSaturation = 0.0
    var count = 0

    for y in Swift.stride(from: bounds.top, through: bounds.bottom, by: stride) {
        for x in Swift.stride(from: bounds.left, through: bounds.right, by: stride) {
            let offset = (y * width + x) * 4
            guard offset + 3 < pixels.count, pixels[offset + 3] >= 200 else { continue }
            let color = RGBColor(
                r: Int(pixels[offset]),
                g: Int(pixels[offset + 1]),
                b: Int(pixels[offset + 2])
            )
            totalLuminance += color.luminance
            totalSaturation += color.hsl.saturation
            count += 1
        }
    }

    // No opaque pixels at all reads as "light", so a fully transparent image
    // falls back to the ordinary dark neutral rather than a white tile.
    guard count > 0 else { return (1, 0) }
    return (totalLuminance / Double(count), totalSaturation / Double(count))
}

/// Reads the border ring of raw RGBA pixels and decides what background, if
/// any, the logo is mounted on.
func backgroundFromRGBA(
    pixels: [UInt8],
    width: Int,
    height: Int,
    sampleCount: Int = 40
) -> RGBColor? {
    guard width >= 8, height >= 8 else { return nil }

    // Trim transparent padding first. Logos are routinely a square canvas with
    // wide artwork centred in it, leaving see-through bands above and below;
    // sampling the untrimmed edges reads those bands as "no plate" and rejects
    // an image that plainly has one.
    guard let bounds = opaqueBounds(pixels, width, height) else { return nil }
    let boxLeft = bounds.left
    let boxTop = bounds.top
    let boxWidth = bounds.right - bounds.left + 1
    let boxHeight = bounds.bottom - bounds.top + 1
    guard boxWidth >= 8, boxHeight >= 8 else { return nil }

    // A plate is a solid rectangle. A cut-out mark trimmed to its bounding box
    // is not: it is mostly gaps between glyphs. Without this, trimming would
    // hand back the mark's own colour as a background.
    guard isSolid(pixels, width, boxLeft, boxTop, boxWidth, boxHeight) else { return nil }

    // Scaled artwork often has an anti-aliased rim, so skip more than a pixel.
    let inset = max(2, Int((Double(min(boxWidth, boxHeight)) * 0.03).rounded()))
    let band = max(1, Int((Double(boxWidth) * 0.08).rounded()))

    var left: [Int] = []
    var right: [Int] = []

    let steps = min(max(sampleCount, 4), 200)
    for i in 0..<steps {
        let t = Double(i) / Double(steps - 1)
        let y = min(
            max(Int((Double(boxTop + inset) + t * Double(boxHeight - 1 - 2 * inset)).rounded()), 0),
            height - 1
        )
        // A few columns in from each edge of the trimmed box.
        for d in 0..<3 {
            let lx = min(
                max(Int((Double(boxLeft + inset) + Double(d) * (Double(band) / 3)).rounded()), 0),
                width - 1
            )
            let rx = min(
                max(
                    Int(
                        (Double(boxLeft + boxWidth - 1 - inset) - Double(d) * (Double(band) / 3))
                            .rounded()), 0),
                width - 1
            )
            left.append((y * width + lx) * 4)
            right.append((y * width + rx) * 4)
        }
    }

    guard let leftColor = flatColor(pixels, left), let rightColor = flatColor(pixels, right) else {
        // Either side see-through or busy means there is no plate to borrow.
        return nil
    }

    if channelDistance(leftColor, rightColor) <= 60 {
        // One plate across the whole image; average out sampling noise.
        return RGBColor(
            red: (leftColor.red + rightColor.red) / 2,
            green: (leftColor.green + rightColor.green) / 2,
            blue: (leftColor.blue + rightColor.blue) / 2
        )
    }

    return preferredMatchupBackground(leftColor, rightColor)
}

/// The rectangle of pixels that actually carries opaque content.
struct OpaqueBounds: Equatable {
    let left: Int
    let top: Int
    let right: Int
    let bottom: Int
}

/// Bounding box of opaque pixels, or nil when the image is fully transparent.
func opaqueBounds(_ pixels: [UInt8], _ width: Int, _ height: Int) -> OpaqueBounds? {
    let stride = max(1, min(width, height) / 64)
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1

    for y in Swift.stride(from: 0, to: height, by: stride) {
        for x in Swift.stride(from: 0, to: width, by: stride) {
            let offset = (y * width + x) * 4
            guard offset + 3 < pixels.count else { continue }
            guard pixels[offset + 3] >= 200 else { continue }
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= 0, maxY >= 0 else { return nil }
    return OpaqueBounds(left: minX, top: minY, right: maxX, bottom: maxY)
}

/// Whether the trimmed box is filled rather than a sparse mark.
func isSolid(
    _ pixels: [UInt8],
    _ width: Int,
    _ boxLeft: Int,
    _ boxTop: Int,
    _ boxWidth: Int,
    _ boxHeight: Int,
    grid: Int = 24,
    threshold: Double = 0.9
) -> Bool {
    var opaque = 0
    var total = 0
    for gy in 0..<grid {
        for gx in 0..<grid {
            let x = boxLeft + (gx * (boxWidth - 1)) / (grid - 1)
            let y = boxTop + (gy * (boxHeight - 1)) / (grid - 1)
            let offset = (y * width + x) * 4
            guard offset + 3 < pixels.count else { continue }
            total += 1
            if pixels[offset + 3] >= 200 { opaque += 1 }
        }
    }
    return total > 0 && Double(opaque) / Double(total) >= threshold
}

/// Representative colour of `offsets`, or nil when they are translucent or too
/// varied to be a flat plate.
func flatColor(_ pixels: [UInt8], _ offsets: [Int]) -> RGBColor? {
    guard !offsets.isEmpty else { return nil }

    var reds: [Int] = []
    var greens: [Int] = []
    var blues: [Int] = []

    for offset in offsets {
        guard offset + 3 < pixels.count else { continue }
        // Anything meaningfully translucent counts as "no plate here".
        guard pixels[offset + 3] >= 200 else { continue }
        reds.append(Int(pixels[offset]))
        greens.append(Int(pixels[offset + 1]))
        blues.append(Int(pixels[offset + 2]))
    }

    guard Double(reds.count) / Double(offsets.count) >= 0.85 else { return nil }

    func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    let r = median(reds)
    let g = median(greens)
    let b = median(blues)

    var agreeing = 0
    for i in 0..<reds.count {
        let delta = abs(reds[i] - r) + abs(greens[i] - g) + abs(blues[i] - b)
        if delta <= 60 { agreeing += 1 }
    }

    // A photo or gradient edge is not a background colour either.
    guard Double(agreeing) / Double(reds.count) >= 0.85 else { return nil }

    return RGBColor(r: r, g: g, b: b)
}

/// Summed per-channel distance between two colours, in 0-255 units.
func channelDistance(_ a: RGBColor, _ b: RGBColor) -> Int {
    Int((abs(a.red - b.red) * 255).rounded())
        + Int((abs(a.green - b.green) * 255).rounded())
        + Int((abs(a.blue - b.blue) * 255).rounded())
}

/// Chooses which half of a split "matchup" plate should colour the tile.
func preferredMatchupBackground(_ a: RGBColor, _ b: RGBColor) -> RGBColor {
    let scoreA = plateScore(a)
    let scoreB = plateScore(b)

    if abs(scoreA - scoreB) < 0.1 {
        return a.hsl.lightness <= b.hsl.lightness ? a : b
    }
    return scoreA > scoreB ? a : b
}

/// How much a colour reads as deliberate branding rather than filler.
func plateScore(_ color: RGBColor) -> Double {
    let hsl = color.hsl
    let washedOut = hsl.lightness < 0.08 || hsl.lightness > 0.92
    return hsl.saturation * (washedOut ? 0.2 : 1.0)
}

/// Muted tile colours for logos with no background of their own.
let kNeutralCardColors: [RGBColor] = [
    RGBColor(r: 0x2B, g: 0x2F, b: 0x36),  // slate
    RGBColor(r: 0x33, g: 0x2F, b: 0x2C),  // warm grey
    RGBColor(r: 0x2A, g: 0x32, b: 0x2E),  // green grey
    RGBColor(r: 0x31, g: 0x2E, b: 0x38),  // violet grey
    RGBColor(r: 0x2E, g: 0x31, b: 0x38),  // blue grey
    RGBColor(r: 0x35, g: 0x30, b: 0x2D),  // taupe
]

/// Tile colours for cut-out logos whose ink is too dark to sit on a dark one.
///
/// Tinted rather than plain white, and matched to `kNeutralCardColors` hue for
/// hue, so a light tile reads as the same family of object as its neighbours
/// rather than as a hole in the grid.
let kLightNeutralCardColors: [RGBColor] = [
    RGBColor(r: 0xDC, g: 0xE0, b: 0xE6),  // slate
    RGBColor(r: 0xE6, g: 0xE1, b: 0xDB),  // warm grey
    RGBColor(r: 0xDB, g: 0xE4, b: 0xDE),  // green grey
    RGBColor(r: 0xE1, g: 0xDD, b: 0xE8),  // violet grey
    RGBColor(r: 0xDD, g: 0xE1, b: 0xE8),  // blue grey
    RGBColor(r: 0xE8, g: 0xE2, b: 0xDC),  // taupe
]

/// A stable neutral for `seed`, so a channel keeps the same colour between
/// launches rather than shuffling on each rebuild.
func neutralCardColor(seed: String) -> RGBColor {
    kNeutralCardColors[neutralIndex(seed: seed)]
}

/// The light counterpart, at the same index — so a channel that switches
/// between them keeps its hue.
func lightNeutralCardColor(seed: String) -> RGBColor {
    kLightNeutralCardColors[neutralIndex(seed: seed)]
}

/// Swift's own `hashValue` is seeded per process and would give a different
/// colour every launch, so this reimplements the Dart hash explicitly.
private func neutralIndex(seed: String) -> Int {
    guard !seed.isEmpty else { return 0 }
    var hash = 0
    for unit in seed.utf16 {
        hash = (hash &* 31 &+ Int(unit)) & 0x7FFF_FFFF
    }
    return hash % kNeutralCardColors.count
}

/// The colour a logo tile should actually be painted.
///
/// One function for every tile in the app — the carousel cards, the guide's
/// pinned column, the detail sheet — because the rule has three branches now and
/// three copies of it would drift the first time any of them is tuned.
func logoTileColor(plate: LogoPlate?, seed: String) -> RGBColor {
    if let background = plate?.background { return background }
    if plate?.needsLightBacking == true { return lightNeutralCardColor(seed: seed) }
    return neutralCardColor(seed: seed)
}

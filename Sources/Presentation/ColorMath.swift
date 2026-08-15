import SwiftUI

/// A plain RGB triple, 0…1 per channel.
struct RGBColor: Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(r: Int, g: Int, b: Int) {
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    var r255: Int { Int((red * 255).rounded()) }
    var g255: Int { Int((green * 255).rounded()) }
    var b255: Int { Int((blue * 255).rounded()) }

    /// WCAG relative luminance.
    var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Whether white or dark text belongs on this colour.
    ///
    var needsDarkForeground: Bool {
        let l = luminance
        return (l + 0.05) * (l + 0.05) > 0.15
    }

    /// The foreground colour for text sitting on this background.
    var foreground: Color { needsDarkForeground ? Color.black.opacity(0.87) : .white }

    /// Composites `self` at `alpha` over `background`.
    func blended(alpha: Double, over background: RGBColor) -> RGBColor {
        RGBColor(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha)
        )
    }

    // MARK: - HSL

    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maxV = max(red, green, blue)
        let minV = min(red, green, blue)
        let delta = maxV - minV
        let lightness = (maxV + minV) / 2

        guard delta > 0 else { return (0, 0, lightness) }

        let saturation =
            lightness > 0.5
            ? delta / (2 - maxV - minV)
            : delta / (maxV + minV)

        var hue: Double
        switch maxV {
        case red: hue = (green - blue) / delta + (green < blue ? 6 : 0)
        case green: hue = (blue - red) / delta + 2
        default: hue = (red - green) / delta + 4
        }
        hue *= 60
        return (hue, saturation, lightness)
    }

    static func fromHSL(hue: Double, saturation: Double, lightness: Double) -> RGBColor {
        let h = hue.truncatingRemainder(dividingBy: 360) / 360
        guard saturation > 0 else {
            return RGBColor(red: lightness, green: lightness, blue: lightness)
        }

        let q = lightness < 0.5
            ? lightness * (1 + saturation)
            : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q

        func component(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }

        return RGBColor(
            red: component(h + 1 / 3),
            green: component(h),
            blue: component(h - 1 / 3)
        )
    }
}

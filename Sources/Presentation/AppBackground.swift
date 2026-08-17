import SwiftUI

/// The app's backdrop: dark at the left and right edges, lifting to a lighter
/// grey through the middle.
///
/// Built from many eased stops rather than the obvious three.
///
/// A three-stop linear gradient interpolates *linearly*, which leaves a visible
/// crease at the midpoint and — across 1920px of TV panel with only ~24 levels
/// of grey to play with — bands into vertical stripes. Sampling a smoothstep
/// curve instead gives the ramp zero gradient at both ends and at the centre, so
/// there is no crease to see, and the extra stops keep each step below the
/// threshold where 8-bit banding shows.
struct AppBackground: View {
    /// The colour at the left and right edges.
    static let edge = RGBColor(r: 0x0C, g: 0x0C, b: 0x0E)

    /// The colour through the centre.
    static let middle = RGBColor(r: 0x2A, g: 0x2A, b: 0x30)

    var body: some View {
        LinearGradient(
            stops: Self.stops,
            startPoint: .leading,
            endPoint: .trailing
        )
        .ignoresSafeArea()
    }

    private static let stops: [Gradient.Stop] = {
        let sampleCount = 17
        return (0..<sampleCount).map { index in
            let t = Double(index) / Double(sampleCount - 1)
            // Distance from the centre, 0 in the middle and 1 at either edge.
            let distance = abs(t - 0.5) * 2
            // smoothstep: flat at both ends, so the ramp eases in and out
            // instead of cornering.
            let weight = distance * distance * (3 - 2 * distance)
            let color = edge.blended(alpha: weight, over: middle)
            return Gradient.Stop(color: color.color, location: t)
        }
    }()
}

private struct SinebowBackground: View {
    @Environment(\.scenePhase) private var scenePhase

    /// Fixed per instance so the animation is a function of elapsed time rather
    /// than of when a given frame happens to be drawn.
    @State private var start = Date()

    /// How much of the shader survives. The one number to turn for brightness.
    private let strength: Double = 0.12

    /// Multiplier on elapsed time, and so on the speed of everything.
    private let speed: Double = 0.25

    /// Redraw interval - 30fps rather than display refresh.
    private let frameInterval: Double = 1.0 / 30.0

    var body: some View {
        ZStack {
            Color.black
            TimelineView(
                .animation(minimumInterval: frameInterval, paused: scenePhase != .active)
            ) { context in
                let elapsed = context.date.timeIntervalSince(start) * speed
                Rectangle()
                    .visualEffect { content, proxy in
                        content.colorEffect(
                            ShaderLibrary.sinebow(
                                .float2(proxy.size),
                                .float(elapsed)
                            )
                        )
                    }
            }
            .opacity(strength)
        }
        .ignoresSafeArea()
        // Purely decorative, and it never stops moving - VoiceOver should not
        // see it at all.
        .accessibilityHidden(true)
    }
}

extension View {
    /// Puts the app backdrop behind this view.
    func appBackground() -> some View {
        modifier(AppBackgroundModifier())
    }
}

private struct AppBackgroundModifier: ViewModifier {
    #if os(tvOS)
        func body(content: Content) -> some View {
            content.background(AppBackground())
        }
    #else
        @RegularWidth private var isRegularWidth

        func body(content: Content) -> some View {
            content.background {
                if isRegularWidth {
                    SinebowBackground()
                }
            }
        }
    #endif
}

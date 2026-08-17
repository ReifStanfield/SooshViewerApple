import SwiftUI

/// Ten-foot layout constants.
enum Layout {
    #if os(tvOS)
        static let isTV = true

        ///. TV panels overscan - the outer few percent of
        /// the signal can be cropped by the display - so content pinned to the
        /// literal edge risks being cut off on real hardware.
        static let screenMarginH: CGFloat = 90
        static let screenMarginV: CGFloat = 54

        /// Spacing between page sections.
        static let sectionSpacing: CGFloat = 48
    #else
        static let isTV = false
        static let screenMarginH: CGFloat = 16
        static let screenMarginV: CGFloat = 0
        static let sectionSpacing: CGFloat = 24
    #endif
}

extension View {
    /// Horizontal inset for page content: overscan-safe on TV, ordinary padding
    /// elsewhere.
    func screenMargin() -> some View {
        padding(.horizontal, Layout.screenMarginH)
    }
}

// MARK: - Focusable button styles

extension View {
    /// Button style for a **card**: a hover lift wherever there is a pointer,
    /// a focus lift on tvOS.
    func cardButtonStyle() -> some View {
        #if os(tvOS)
            buttonStyle(LiftButtonStyle())
        #else
            buttonStyle(HoverCardButtonStyle())
        #endif
    }

    /// Button style for a **list row**: `.plain` on iOS, `.borderless` on tvOS.
    func rowButtonStyle() -> some View {
        #if os(tvOS)
            buttonStyle(.borderless)
        #else
            buttonStyle(.plain)
        #endif
    }

    /// Groups children so the focus engine treats them as one unit.
    ///
    /// Without this, moving the remote up from the guide can land anywhere that
    /// happens to be geometrically nearby rather than on the section above.
    /// `focusSection` makes movement between groups predictable; it is a no-op
    /// off tvOS.
    func tvFocusSection() -> some View {
        #if os(tvOS)
            focusSection()
        #else
            self
        #endif
    }
}

extension View {
    /// Stops a text field auto-capitalising, where that is a thing that happens.
    ///
    /// Wrapped rather than `#if`-ed at each call site, for the same reason as
    /// `inlineNavigationTitle`: the platform difference is a fact about the
    /// modifier, not about the fields that want plain text.
    /// `textInputAutocapitalization` is software-keyboard behaviour and does not
    /// exist on macOS, where a hardware keyboard types exactly what was pressed.
    func plainTextEntry() -> some View {
        #if os(macOS)
            autocorrectionDisabled()
        #else
            autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The trailing end of the navigation chrome, wherever that is.
    ///
    /// `.topBarTrailing` names a *top bar*, which is a UIKit idea and is
    /// unavailable on macOS. AppKit's toolbar has no fixed leading/trailing
    /// halves to ask for, so `.automatic` is the honest answer there and puts
    /// the item in the toolbar's natural position.
    static var trailingAccessory: ToolbarItemPlacement {
        #if os(iOS)
            .topBarTrailing
        #else
            .automatic
        #endif
    }
}

// Every pointer platform, which now means Mac as well as iPad. Excluded on tvOS
// rather than limited to iOS: a remote has focus, not a cursor, and `LiftButtonStyle`
// is that platform's answer.
#if !os(tvOS)

    /// Pointer treatment for a card: a grey plate behind it, and a lift.
    struct HoverCardButtonStyle: ButtonStyle {
        // Named `HoverBody`, not `Body`, for the reason spelled out on
        // `LiftButtonStyle`: `ButtonStyle` has its own `Body` associated type.
        func makeBody(configuration: Configuration) -> some View {
            HoverBody(configuration: configuration)
        }

        struct HoverBody: View {
            let configuration: Configuration

            /// `@State` lives here rather than on the style itself. A
            /// `ButtonStyle` is not a `View`, so state declared on it is never
            /// installed and never updates
            @State private var isHovered = false
            @RegularWidth private var isRegularWidth

            private var metrics: Metrics {
                .resolve(isRegularWidth: isRegularWidth)
            }

            var body: some View {
                configuration.label
                    .background {
                        RoundedRectangle(
                            cornerRadius: logoPlateCornerRadius(forWidth: metrics.cardWidth),
                            style: .continuous
                        )
                        .fill(.white.opacity(isHovered ? 0.12 : 0))
                    }
                    .scaleEffect(scale)
                    .animation(.snappy(duration: 0.18), value: isHovered)
                    .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                    .onHover { isHovered = $0 }
            }

            /// Modest next to the TV's 1.10 - a pointer is inches from the
            /// screen, so it takes far less movement to read as a lift.
            private var scale: CGFloat {
                if configuration.isPressed { return 0.98 }
                return isHovered ? 1.03 : 1.0
            }
        }
    }

#endif

/// A glass button that turns prominent when it is the control you are about to
/// press — hovered by a pointer, or focused by a remote.
///
/// **One style whose material changes, not two styles swapped.** `.glass` and
/// `.glassProminent` are different types, so choosing between them in an
/// `if`/`else` changes the button's identity: SwiftUI tears the old one down and
/// builds a new one, which cannot animate and can drop a press that is in flight
/// across the switch. Tinting a single glass effect crossfades instead.
///
/// The alternative — leaving it prominent and brightening on hover — makes the
/// resting state shout, and `brightness` over an already-bright fill washes the
/// label out rather than lighting the button.
struct HoverGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassBody(configuration: configuration)
    }

    struct GlassBody: View {
        let configuration: Configuration

        /// State and environment both have to live on a `View`. A `ButtonStyle`
        /// is not one, so neither would ever update if declared on the style —
        /// the same reason `HoverCardButtonStyle` has an inner view.
        @State private var isHovered = false

        #if os(tvOS)
            @Environment(\.isFocused) private var isFocused
        #endif

        /// **Focus only counts on tvOS.** OR-ing the two looked equivalent — a
        /// pointer never focuses, a remote never hovers — but on iPadOS a sheet
        /// hands keyboard focus to its only control, so the button came up
        /// prominent at rest and never changed. Focus means "the remote is
        /// here" on a television and "the keyboard would type here" on an iPad,
        /// and only the first is what this is asking about.
        private var isActive: Bool {
            #if os(tvOS)
                return isFocused
            #else
                return isHovered
            #endif
        }

        var body: some View {
            configuration.label
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .foregroundStyle(isActive ? Color.white : .primary)
                .glassEffect(
                    isActive
                        ? .regular.tint(.accentColor).interactive()
                        : .regular.interactive(),
                    in: Capsule()
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeInOut(duration: 0.22), value: isActive)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                // Unavailable on tvOS rather than inert there — it fails the
                // build. `isFocused` is what drives this on a television.
                #if !os(tvOS)
                    .onHover { isHovered = $0 }
                #endif
        }
    }
}

#if os(tvOS)

    struct LiftButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            LiftBody(configuration: configuration)
        }

        struct LiftBody: View {
            let configuration: Configuration
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .scaleEffect(scale)
                    .shadow(
                        color: .black.opacity(isFocused ? 0.55 : 0),
                        radius: isFocused ? 28 : 0,
                        y: isFocused ? 18 : 0
                    )
                    .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isFocused)
                    .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            }

            private var scale: CGFloat {
                if configuration.isPressed { return 1.02 }
                return isFocused ? 1.10 : 1.0
            }
        }
    }

    /// Focus treatment for a guide block: an outline, not a lift.
    struct FocusOutlineButtonStyle: ButtonStyle {
        var cornerRadius: CGFloat = 8

        func makeBody(configuration: Configuration) -> some View {
            OutlineBody(configuration: configuration, cornerRadius: cornerRadius)
        }

        struct OutlineBody: View {
            let configuration: Configuration
            let cornerRadius: CGFloat
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.white, lineWidth: isFocused ? 4 : 0)
                            .padding(.vertical, 4)
                            .padding(.trailing, 2)
                    }
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }

#endif

extension View {
    /// Focus treatment for a programme block in the guide.
    @ViewBuilder
    func guideBlockButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(FocusOutlineButtonStyle())
        #else
        self.modifier(HoverablePlainButtonModifier())
        #endif
    }
}

#if !os(tvOS)
private struct HoverablePlainButtonModifier: ViewModifier {
    @State private var isHovered: Bool = false
    
    func body(content: Content) -> some View {
        content.buttonStyle(.plain)
            .brightness(isHovered ? 0.2 : 0)
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .onHover { hovering in
            isHovered = hovering
        }
    }
}
#endif


import SwiftUI

/// "Is this a wide layout?", answerable on every platform.
///
/// **`horizontalSizeClass` does not exist on macOS.** It is not deprecated
/// there and it is not merely unset — `UserInterfaceSizeClass` is marked
/// unavailable, so a bare `@Environment(\.horizontalSizeClass)` fails the Mac
/// build outright. That mattered here because eight views read it, all of them
/// only to answer this one question before handing the answer to
/// `GuideGeometry.resolve(isRegularWidth:)`.
///
/// So the question gets a type and the platforms get their own answers:
///
/// - **iOS** keeps the real size class, because the distinction is live there:
///   an iPad in Slide Over is compact and must lay out like a phone, and the
///   user can change it by dragging.
/// - **macOS** is always regular. A Mac window can be dragged narrow, but AppKit
///   has no compact idiom to fall back to and the phone's tab bar is not what a
///   narrow Mac window should become.
/// - **tvOS** is always regular for a blunter reason: a 1080p TV is 1920pt wide,
///   so the size class says "regular" anyway. `GuideGeometry.guideRowCount`
///   already overrides the row budget on TV rather than trusting the width.
///
/// Used as a property wrapper so call sites read as a fact about the layout
/// rather than a platform check:
///
/// ```swift
/// @RegularWidth private var isRegularWidth
/// ```
///
/// It is a `DynamicProperty`, so the `@Environment` read inside it still
/// invalidates the view on iOS when the size class actually changes.
@propertyWrapper
struct RegularWidth: DynamicProperty {
    #if os(iOS)

        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        var wrappedValue: Bool { horizontalSizeClass == .regular }

    #else

        var wrappedValue: Bool { true }

    #endif

    init() {}
}

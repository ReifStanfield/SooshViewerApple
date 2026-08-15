import SwiftUI

/// App entry point — the counterpart of `void main()` plus `MyApp`.
///
/// `@main` on a `struct: App` replaces `runApp()`. There is no `MaterialApp`
/// wrapper: theming comes from environment modifiers and the asset catalog.
@main
struct SooshViewerApp: App {
    /// One client for the app's lifetime, so the JWT pair and the logo cache
    /// are shared. Created here rather than in a view, since views get rebuilt.
    @State private var client = DispatcharrClient(baseURL: AppConfig.baseURL)

    /// App-level so settings survive closing and reopening the sheet.
    @State private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            RootView(client: client)
                .environment(settings)
                // The Flutter app pins dark (`autoTheming: false`). Same here,
                // and for the same reason: the guide's palette is dark-only.
                .preferredColorScheme(.dark)
        }
        // Opening size for a resizable window — iPadOS 26 and Mac.
        //
        // Wide on purpose: the guide is a timeline, so horizontal space is the
        // one dimension that buys more of the product. 1200pt also lands well
        // clear of the 840pt regular-width threshold, so the app opens with the
        // sidebar rather than the phone's tab bar.
        //
        // **Initial size only.** The user can still resize freely, and it is
        // ignored outright when the window opens full screen. Constraining that
        // is `.windowResizability`, deliberately not set: `.contentSize` would
        // clamp the window to what the content asks for, and the guide always
        // wants every point it can get.
        //
        // The `#if` is not tidiness — both of these are marked unavailable on
        // tvOS and fail the TV build outright.
        #if !os(tvOS)
            .defaultSize(width: 1400, height: 1000)
        #endif
    }
}

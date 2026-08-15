import Foundation

/// Server connection settings, supplied at build time.
///
/// The Flutter app reads these from `--dart-define`, which resolves at compile
/// time via `String.fromEnvironment`. Swift has no equivalent, so the values
/// travel through the build settings in `Config/Local.xcconfig` into
/// `Info.plist`, and are read back out of the bundle here.
///
/// Same trade-off as `--dart-define`: nothing lands in source control, but the
/// values *are* present in the shipped bundle. A real login flow writing to the
/// Keychain should replace this.
enum AppConfig {
    static let baseURL = infoValue("DISPATCHARR_URL")
    static let username = infoValue("DISPATCHARR_USER")
    static let password = infoValue("DISPATCHARR_PASS")

    static var hasServer: Bool { !baseURL.isEmpty }
    static var hasCredentials: Bool { !username.isEmpty && !password.isEmpty }

    private static func infoValue(_ key: String) -> String {
        // `object(forKey:)` rather than subscripting Bundle.main.infoDictionary
        // directly so a missing key is nil rather than a crash in a stripped
        // build.
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

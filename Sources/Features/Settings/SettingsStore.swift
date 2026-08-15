import Observation
import SwiftUI

/// The values the settings screens edit.
///
/// **Nothing consumes these yet**, exactly as in Flutter — the screens exist and
/// the controls move, but no other part of the app reads them. They are kept
/// here rather than in each page's own state so they survive closing and
/// reopening the sheet, which the Flutter version does not: `SettingsDetailPage`
/// is a `StatefulWidget` rebuilt on every push, so its frequency and toggles
/// reset each time.
///
/// Deliberately *not* `@AppStorage`: persisting settings that do not yet affect
/// anything would make them look wired up when they are not.
@MainActor
@Observable
final class SettingsStore {
    var updateFrequency: UpdateFrequency = .daily
    var userAgent: String = ""
    var useRemoteSettings: Bool = false
    var streamFormat: StreamFormat = .ts

    enum UpdateFrequency: Int, CaseIterable, Identifiable {
        case manually, daily, weekly, monthly

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .manually: return "Manually"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            }
        }

        /// Clamped rather than wrapping, matching the Dart original — the
        /// stepper's buttons disable at the ends instead of cycling.
        var next: UpdateFrequency {
            UpdateFrequency(rawValue: min(rawValue + 1, Self.allCases.count - 1)) ?? self
        }

        var previous: UpdateFrequency {
            UpdateFrequency(rawValue: max(rawValue - 1, 0)) ?? self
        }
    }

    enum StreamFormat: String, CaseIterable, Identifiable {
        case ts, m3u8

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ts: return "TS (.ts)"
            case .m3u8: return "M3U8 (.m3u8)"
            }
        }
    }
}

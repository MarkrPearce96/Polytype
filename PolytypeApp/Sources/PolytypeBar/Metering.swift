import Foundation
import TranslationCore

/// Shared access to the usage meter (set by AppDelegate) plus the shared
/// reset date string used by the menu and Settings.
@MainActor
enum MeterAccess {
    static var meter: UsageMeter?

    /// Human date the free tier next resets, e.g. "Aug 3".
    static func resetDateString() -> String {
        guard let date = meter?.nextResetDate else { return "next month" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

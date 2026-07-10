import Foundation
import TranslationCore

/// Shared access to the usage meter (set by AppDelegate) plus the shared
/// month-reset date string used by the menu and Settings.
@MainActor
enum MeterAccess {
    static var meter: UsageMeter?

    /// Current month's Gregorian key, e.g. "2026-7". `nonisolated` since it
    /// touches no actor state and is called from the meter's `@Sendable` month
    /// closure, which may run off the main actor.
    nonisolated static func currentMonthKey() -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }

    /// Human date the free tier resets (first of next month), e.g. "Aug 1".
    static func resetDateString() -> String {
        let cal = Calendar.current
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())),
              let next = cal.date(byAdding: .month, value: 1, to: start) else { return "next month" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: next)
    }
}

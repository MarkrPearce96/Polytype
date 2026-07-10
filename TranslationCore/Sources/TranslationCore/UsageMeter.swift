import Foundation

/// Persisted backing for the usage meter. Injectable so the meter is testable
/// without `UserDefaults`.
public protocol UsageStore: Sendable {
    func int(_ key: String) -> Int
    func setInt(_ value: Int, _ key: String)
    func string(_ key: String) -> String?
    func setString(_ value: String?, _ key: String)
    func bool(_ key: String) -> Bool
    func setBool(_ value: Bool, _ key: String)
    func double(_ key: String) -> Double
    func setDouble(_ value: Double, _ key: String)
}

/// Production `UsageStore` backed by `UserDefaults`. `UserDefaults` is
/// documented as thread-safe, hence `@unchecked Sendable`.
public final class UserDefaultsUsageStore: UsageStore, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func int(_ key: String) -> Int { defaults.integer(forKey: key) }
    public func setInt(_ value: Int, _ key: String) { defaults.set(value, forKey: key) }
    public func string(_ key: String) -> String? { defaults.string(forKey: key) }
    public func setString(_ value: String?, _ key: String) { defaults.set(value, forKey: key) }
    public func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    public func setBool(_ value: Bool, _ key: String) { defaults.set(value, forKey: key) }
    public func double(_ key: String) -> Double { defaults.double(forKey: key) }
    public func setDouble(_ value: Double, _ key: String) { defaults.set(value, forKey: key) }
}

/// Tracks Google character usage against the monthly free tier, resetting when
/// the stored reset date passes. Thread-safe.
public final class UsageMeter: @unchecked Sendable {
    public let limit = 500_000
    public let cap = 490_000

    private let store: UsageStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    private enum Key {
        static let used = "usage.used"
        static let notified = "usage.notified"
        static let nextReset = "usage.nextReset"   // timeIntervalSinceReferenceDate
    }

    public init(store: UsageStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// First of the month after `date` — the default reset when uncalibrated.
    private func firstOfNextMonth(after date: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
        return cal.date(byAdding: .month, value: 1, to: startOfMonth) ?? date.addingTimeInterval(2_592_000)
    }

    /// Caller holds `lock`. Zero the count when the reset date has passed,
    /// advancing the reset date by whole months until it's in the future.
    private func rolloverIfNeeded() {
        let current = now()
        let stored = store.double(Key.nextReset)
        var next = (stored == 0) ? firstOfNextMonth(after: current)
                                 : Date(timeIntervalSinceReferenceDate: stored)
        if current >= next {
            let cal = Calendar(identifier: .gregorian)
            while current >= next {
                next = cal.date(byAdding: .month, value: 1, to: next) ?? next.addingTimeInterval(2_592_000)
            }
            store.setInt(0, Key.used)
            store.setBool(false, Key.notified)
            store.setDouble(next.timeIntervalSinceReferenceDate, Key.nextReset)
        } else if stored == 0 {
            store.setDouble(next.timeIntervalSinceReferenceDate, Key.nextReset)   // persist the default
        }
    }

    public var used: Int {
        lock.lock(); defer { lock.unlock() }; rolloverIfNeeded(); return store.int(Key.used)
    }

    public var nextResetDate: Date {
        lock.lock(); defer { lock.unlock() }; rolloverIfNeeded()
        return Date(timeIntervalSinceReferenceDate: store.double(Key.nextReset))
    }

    public func canUseGoogle(adding chars: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; rolloverIfNeeded(); return store.int(Key.used) + chars <= cap
    }

    public func record(_ chars: Int) {
        lock.lock(); defer { lock.unlock() }; rolloverIfNeeded()
        store.setInt(store.int(Key.used) + chars, Key.used)
    }

    public var hasNotified: Bool {
        lock.lock(); defer { lock.unlock() }; rolloverIfNeeded(); return store.bool(Key.notified)
    }

    public func markNotified() {
        lock.lock(); defer { lock.unlock() }; rolloverIfNeeded(); store.setBool(true, Key.notified)
    }

    /// Set the counter to a known-exact value and renewal date (from the user).
    public func calibrate(used chars: Int, nextReset date: Date) {
        lock.lock(); defer { lock.unlock() }
        store.setInt(max(0, chars), Key.used)
        store.setDouble(date.timeIntervalSinceReferenceDate, Key.nextReset)
        store.setBool(false, Key.notified)
    }
}

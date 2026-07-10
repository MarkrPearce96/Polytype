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
}

/// Tracks Google character usage against the monthly free tier, resetting when
/// the calendar month changes. Thread-safe.
public final class UsageMeter: @unchecked Sendable {
    public let limit = 500_000
    public let cap = 490_000

    private let store: UsageStore
    private let month: @Sendable () -> String
    private let lock = NSLock()

    private enum Key {
        static let used = "usage.used"
        static let month = "usage.month"
        static let notified = "usage.notified"
    }

    public init(store: UsageStore, month: @escaping @Sendable () -> String) {
        self.store = store
        self.month = month
    }

    /// Caller must hold `lock`. Zeroes the count when the month changed.
    private func rolloverIfNeeded() {
        let current = month()
        if store.string(Key.month) != current {
            store.setString(current, Key.month)
            store.setInt(0, Key.used)
            store.setBool(false, Key.notified)
        }
    }

    public var used: Int {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeeded()
        return store.int(Key.used)
    }

    public func canUseGoogle(adding chars: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeeded()
        return store.int(Key.used) + chars <= cap
    }

    public func record(_ chars: Int) {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeeded()
        store.setInt(store.int(Key.used) + chars, Key.used)
    }

    public var hasNotified: Bool {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeeded()
        return store.bool(Key.notified)
    }

    public func markNotified() {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeeded()
        store.setBool(true, Key.notified)
    }
}

# Usage Calibration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user set the counter to their exact current Google usage and their real renewal date; the counter then resets on that date, which rolls forward one month automatically.

**Architecture:** Replace `UsageMeter`'s `"year-month"` reset key with a stored **next-reset `Date`** (driven by an injected clock), defaulting to the first of next month. Add a `calibrate(used:nextReset:)` method. Settings gets a number field + date picker + Update button. The money-gating (`canUseGoogle`/`record`/cap) is unchanged.

**Tech Stack:** Swift 5.9, AppKit/SwiftUI, SwiftPM, XCTest. macOS 14 floor.

## Global Constraints

- `swift-tools-version: 5.9`; floor `.macOS(.v14)`; zero compiler warnings.
- `UsageMeter` stays `@unchecked Sendable` + `NSLock`; money-gating unchanged (`limit=500_000`, `cap=490_000`, `canUseGoogle`/`record` behavior identical).
- Reset date stored as `timeIntervalSinceReferenceDate` (a `Double`); all date math uses `Calendar(identifier: .gregorian)`.
- Uncalibrated default reset = **first of next month** relative to `now()`.
- Core tests: `swift test --package-path TranslationCore`. App build: `swift build --package-path TypeTranslatorApp`.

---

### Task 1: Date-based reset model + calibrate (TranslationCore + app call sites)

**Files:**
- Modify: `TranslationCore/Sources/TranslationCore/UsageMeter.swift`
- Modify test: `TranslationCore/Tests/TranslationCoreTests/UsageMeterTests.swift`
- Modify test: `TranslationCore/Tests/TranslationCoreTests/QuotaGateTests.swift`
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift`
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/Metering.swift`

**Interfaces:**
- Produces: `UsageStore` gains `double(_:)`/`setDouble(_:_:)`; `UsageMeter(store:now:)` (clock replaces the month closure), `var nextResetDate: Date`, `func calibrate(used:nextReset:)`. Existing `used`/`canUseGoogle`/`record`/`hasNotified`/`markNotified` unchanged in signature.

- [ ] **Step 1: Rewrite UsageMeterTests for the date-based model (write first — will fail)**

Replace the body of `UsageMeterTests.swift` with:

```swift
import XCTest
@testable import TranslationCore

private final class FakeStore: UsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ints: [String: Int] = [:]; private var strings: [String: String] = [:]
    private var bools: [String: Bool] = [:]; private var doubles: [String: Double] = [:]
    func int(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; return ints[k] ?? 0 }
    func setInt(_ v: Int, _ k: String) { lock.lock(); ints[k] = v; lock.unlock() }
    func string(_ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return strings[k] }
    func setString(_ v: String?, _ k: String) { lock.lock(); strings[k] = v; lock.unlock() }
    func bool(_ k: String) -> Bool { lock.lock(); defer { lock.unlock() }; return bools[k] ?? false }
    func setBool(_ v: Bool, _ k: String) { lock.lock(); bools[k] = v; lock.unlock() }
    func double(_ k: String) -> Double { lock.lock(); defer { lock.unlock() }; return doubles[k] ?? 0 }
    func setDouble(_ v: Double, _ k: String) { lock.lock(); doubles[k] = v; lock.unlock() }
}

private final class Clock: @unchecked Sendable { var date: Date; init(_ d: Date) { date = d } }

final class UsageMeterTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }
    private func meter(_ clock: Clock) -> UsageMeter { UsageMeter(store: FakeStore(), now: { clock.date }) }

    func testRecordAccumulatesAndCapBoundary() {
        let m = meter(Clock(date(2026, 7, 10)))
        m.record(100); m.record(50)
        XCTAssertEqual(m.used, 150)
        m.record(489_800)                             // 489_950
        XCTAssertTrue(m.canUseGoogle(adding: 50))     // 490_000 <= cap
        XCTAssertFalse(m.canUseGoogle(adding: 51))    // 490_001 > cap
    }

    func testCalibrateSetsUsedAndResetAndClearsNotified() {
        let m = meter(Clock(date(2026, 7, 10)))
        m.markNotified()
        m.calibrate(used: 42_000, nextReset: date(2026, 8, 3))
        XCTAssertEqual(m.used, 42_000)
        XCTAssertEqual(m.nextResetDate, date(2026, 8, 3))
        XCTAssertFalse(m.hasNotified)
    }

    func testNoResetBeforeDate() {
        let clock = Clock(date(2026, 7, 10))
        let m = meter(clock)
        m.calibrate(used: 1000, nextReset: date(2026, 8, 3)); m.markNotified()
        clock.date = date(2026, 8, 2)
        XCTAssertEqual(m.used, 1000)
        XCTAssertTrue(m.hasNotified)
    }

    func testResetAtDateAdvancesOneMonth() {
        let clock = Clock(date(2026, 7, 10))
        let m = meter(clock)
        m.calibrate(used: 1000, nextReset: date(2026, 8, 3)); m.markNotified()
        clock.date = date(2026, 8, 3)
        XCTAssertEqual(m.used, 0)
        XCTAssertFalse(m.hasNotified)
        XCTAssertEqual(m.nextResetDate, date(2026, 9, 3))
    }

    func testLongGapAdvancesToFirstFutureBoundary() {
        let clock = Clock(date(2026, 7, 10))
        let m = meter(clock)
        m.calibrate(used: 1000, nextReset: date(2026, 8, 3))
        clock.date = date(2026, 11, 20)
        XCTAssertEqual(m.used, 0)
        XCTAssertEqual(m.nextResetDate, date(2026, 12, 3))
    }

    func testUncalibratedDefaultIsFirstOfNextMonth() {
        let m = meter(Clock(date(2026, 7, 10)))
        XCTAssertEqual(m.nextResetDate, date(2026, 8, 1))
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --package-path TranslationCore 2>&1 | tail -5`
Expected: compile failure — `UsageMeter(store:now:)`, `nextResetDate`, `calibrate`, and `setDouble` don't exist yet.

- [ ] **Step 3: Update UsageStore + UserDefaultsUsageStore**

In `UsageMeter.swift`, add to the `UsageStore` protocol:

```swift
    func double(_ key: String) -> Double
    func setDouble(_ value: Double, _ key: String)
```

And to `UserDefaultsUsageStore`:

```swift
    public func double(_ key: String) -> Double { defaults.double(forKey: key) }
    public func setDouble(_ value: Double, _ key: String) { defaults.set(value, forKey: key) }
```

- [ ] **Step 4: Rewrite UsageMeter for the date-based reset**

Replace the `UsageMeter` class body (keep `limit`/`cap`) with:

```swift
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
```

- [ ] **Step 5: Run UsageMeterTests to confirm they pass**

Run: `swift test --package-path TranslationCore --filter UsageMeterTests 2>&1 | grep -E "Executed|failed" | tail -1`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 6: Fix QuotaGateTests for the new init + store**

In `QuotaGateTests.swift`, add the two `double`/`setDouble` methods to `FakeStore2` (same bodies as `FakeStore` above), and change the `meter()` helper from the month closure to a fixed clock:

```swift
    private func meter() -> UsageMeter {
        UsageMeter(store: FakeStore2(), now: { Date(timeIntervalSinceReferenceDate: 800_000_000) })
    }
```

- [ ] **Step 7: Update the app call sites so it still compiles**

In `AppDelegate.swift`, change the meter construction from the month closure to the clock:

```swift
let meter = UsageMeter(store: UserDefaultsUsageStore(), now: { Date() })
```

In `Metering.swift`, delete `currentMonthKey()` and rewrite `resetDateString()` to format the meter's reset date:

```swift
/// Human date the free tier next resets, e.g. "Aug 3".
static func resetDateString() -> String {
    guard let date = meter?.nextResetDate else { return "next month" }
    let f = DateFormatter(); f.dateFormat = "MMM d"
    return f.string(from: date)
}
```

- [ ] **Step 8: Full core suite + app build**

Run: `swift test --package-path TranslationCore 2>&1 | grep -E "Executed [0-9]+ tests|error:|warning:" | tail -1`
Expected: `Executed 50 tests, with 0 failures` (48 − old 4 UsageMeter tests + 6 new = 50), zero warnings.
Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 9: Commit**

```bash
git add TranslationCore TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift TypeTranslatorApp/Sources/TypeTranslatorBar/Metering.swift
git commit -m "feat: date-based usage reset + calibrate(used:nextReset:)"
```

---

### Task 2: Settings calibration control

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/SettingsWindow.swift`

**Interfaces:**
- Consumes: `MeterAccess.meter` (`calibrate(used:nextReset:)`, `nextResetDate`), `MeterAccess.resetDateString()`.

- [ ] **Step 1: Add state for the calibration inputs**

In `SettingsView`, add:

```swift
@State private var usageInput: String = ""
@State private var renewDate: Date = Date()   // seeded from the meter in .onAppear
```

- [ ] **Step 2: Add the calibration controls to the Usage section**

In the `Section("Usage")`, after the existing summary `Text` and the "View exact usage…" button, add:

```swift
Divider()
Text("Match this to your Google account: enter this month's exact character count and the date it renews.")
    .font(.caption).foregroundStyle(.secondary)
LabeledContent("Current usage") {
    TextField("e.g. 42000", text: $usageInput).frame(width: 130)
}
DatePicker("Renews on", selection: $renewDate, displayedComponents: .date)
Button("Update usage & renewal") {
    let digits = usageInput.filter(\.isNumber)
    guard let count = Int(digits), let meter = MeterAccess.meter else {
        status = "Enter a whole number for current usage."
        return
    }
    meter.calibrate(used: count, nextReset: renewDate)
    usageInput = ""
    status = "Usage set to \(count.formatted()); renews \(MeterAccess.resetDateString())."
}
```

- [ ] **Step 3: Seed the date picker from the meter on appear**

The `SettingsView` already has an `.onAppear { key = ... }`. Add to that same closure:

```swift
    renewDate = MeterAccess.meter?.nextResetDate ?? Date()
```

- [ ] **Step 4: Build + manual check**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1` → `Build complete!`, zero warnings.
Then rebuild/relaunch, open Settings: enter a usage number + pick a renewal date + Update → the summary and the menu usage row reflect the new number, and the reset date shows the chosen date.

- [ ] **Step 5: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/SettingsWindow.swift
git commit -m "feat: Settings calibration — set exact usage + renewal date"
```

---

### Task 3: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document calibration**

In `README.md`, near the usage-tracking note, add a sentence: you can calibrate the counter to your account in Settings — enter your exact current character count (from the Google console) and your renewal date; it then resets on that date, rolling forward monthly.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document usage calibration"
```

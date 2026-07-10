# Monthly Usage Counter + Auto-Protect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track Google character usage against the 500k/month free tier, display it, and never let the user be charged by routing over-cap translations to Apple on-device — with a one-time monthly notification when it caps.

**Architecture:** A tested `UsageMeter` (TranslationCore) counts successful Google characters and resets by calendar month. A `QuotaGate` engine wraps Google: under the 490k safety cap it translates and records; over it, it throws so the existing `FallbackChain` uses Apple. The app displays the meter (menu + Settings) and fires the notification.

**Tech Stack:** Swift 5.9, AppKit/SwiftUI, UserNotifications, SwiftPM, XCTest. macOS 14 floor; Apple Translation gated to macOS 15+.

## Global Constraints

- `swift-tools-version: 5.9`; floor `.macOS(.v14)`; macOS-15-only API gated `@available(macOS 15.0, *)`.
- Engines/meter remain `Sendable` (or `@unchecked Sendable` + lock).
- Zero compiler warnings.
- Free limit `500_000`; safety cap `490_000`. Characters counted as `text.unicodeScalars.count`.
- Month key format: `"<year>-<month>"` from the Gregorian calendar (e.g. `"2026-7"`). Reset is calendar-month.
- Google Cloud console URL: `https://console.cloud.google.com/apis/api/translate.googleapis.com/metrics`
- Core tests: `swift test --package-path TranslationCore`. App build: `swift build --package-path TypeTranslatorApp`.

---

### Task 1: UsageMeter + UsageStore (TranslationCore)

**Files:**
- Create: `TranslationCore/Sources/TranslationCore/UsageMeter.swift`
- Create test: `TranslationCore/Tests/TranslationCoreTests/UsageMeterTests.swift`

**Interfaces:**
- Produces: `UsageStore` protocol; `UserDefaultsUsageStore`; `UsageMeter` with `limit`, `cap`, `used`, `canUseGoogle(adding:)`, `record(_:)`, `hasNotified`, `markNotified()` — all rolling over by month internally.

- [ ] **Step 1: Write the failing tests**

Create `UsageMeterTests.swift`:

```swift
import XCTest
@testable import TranslationCore

private final class FakeStore: UsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ints: [String: Int] = [:]
    private var strings: [String: String] = [:]
    private var bools: [String: Bool] = [:]
    func int(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return ints[key] ?? 0 }
    func setInt(_ v: Int, _ key: String) { lock.lock(); ints[key] = v; lock.unlock() }
    func string(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return strings[key] }
    func setString(_ v: String?, _ key: String) { lock.lock(); strings[key] = v; lock.unlock() }
    func bool(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return bools[key] ?? false }
    func setBool(_ v: Bool, _ key: String) { lock.lock(); bools[key] = v; lock.unlock() }
}

final class UsageMeterTests: XCTestCase {
    private func meter(month: @escaping @Sendable () -> String) -> UsageMeter {
        UsageMeter(store: FakeStore(), month: month)
    }

    func testRecordAccumulates() {
        let m = meter { "2026-7" }
        m.record(100); m.record(50)
        XCTAssertEqual(m.used, 150)
    }

    func testCanUseGoogleFalseOverCap() {
        let m = meter { "2026-7" }
        m.record(489_950)
        XCTAssertTrue(m.canUseGoogle(adding: 50))    // 490_000 <= cap
        XCTAssertFalse(m.canUseGoogle(adding: 51))   // 490_001 > cap
    }

    func testMonthRolloverResets() {
        final class MonthBox: @unchecked Sendable { var value: String; init(_ v: String) { value = v } }
        let box = MonthBox("2026-7")
        let m = UsageMeter(store: FakeStore(), month: { box.value })
        m.record(1000); m.markNotified()
        XCTAssertEqual(m.used, 1000)
        XCTAssertTrue(m.hasNotified)
        box.value = "2026-8"
        XCTAssertEqual(m.used, 0)           // rolled over
        XCTAssertFalse(m.hasNotified)       // re-armed
    }

    func testNotifiedFlagWithinMonth() {
        let m = meter { "2026-7" }
        XCTAssertFalse(m.hasNotified)
        m.markNotified()
        XCTAssertTrue(m.hasNotified)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `swift test --package-path TranslationCore 2>&1 | tail -5`
Expected: compile failure — `UsageStore` / `UsageMeter` don't exist yet.

- [ ] **Step 3: Implement UsageMeter.swift**

```swift
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

/// Production `UsageStore` backed by `UserDefaults`.
public final class UserDefaultsUsageStore: UsageStore {
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
```

- [ ] **Step 4: Run tests to confirm they pass**

Run: `swift test --package-path TranslationCore --filter UsageMeterTests 2>&1 | grep -E "Executed|failed" | tail -1`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add TranslationCore/Sources/TranslationCore/UsageMeter.swift TranslationCore/Tests/TranslationCoreTests/UsageMeterTests.swift
git commit -m "feat: UsageMeter — monthly Google character counter with rollover"
```

---

### Task 2: QuotaGate (TranslationCore)

**Files:**
- Create: `TranslationCore/Sources/TranslationCore/QuotaGate.swift`
- Create test: `TranslationCore/Tests/TranslationCoreTests/QuotaGateTests.swift`

**Interfaces:**
- Consumes: `UsageMeter`, `TranslationEngine`, `TranslationError`.
- Produces: `QuotaGate(primary:meter:)` — a `TranslationEngine` that throws `.quotaExceeded` when over the cap (without calling the primary) and otherwise delegates, recording the scalar count only on success.

- [ ] **Step 1: Write the failing tests**

Create `QuotaGateTests.swift`:

```swift
import XCTest
@testable import TranslationCore

private final class FakeStore2: UsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ints: [String: Int] = [:]; private var strings: [String: String] = [:]; private var bools: [String: Bool] = [:]
    func int(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return ints[key] ?? 0 }
    func setInt(_ v: Int, _ key: String) { lock.lock(); ints[key] = v; lock.unlock() }
    func string(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return strings[key] }
    func setString(_ v: String?, _ key: String) { lock.lock(); strings[key] = v; lock.unlock() }
    func bool(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return bools[key] ?? false }
    func setBool(_ v: Bool, _ key: String) { lock.lock(); bools[key] = v; lock.unlock() }
}

private final class SpyEngine: TranslationEngine, @unchecked Sendable {
    var called = false
    var result: Result<String, Error>
    init(_ result: Result<String, Error>) { self.result = result }
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        called = true
        return try result.get()
    }
}

final class QuotaGateTests: XCTestCase {
    private func meter() -> UsageMeter { UsageMeter(store: FakeStore2(), month: { "2026-7" }) }

    func testUnderCapDelegatesAndRecords() async throws {
        let m = meter()
        let spy = SpyEngine(.success("你好"))
        let gate = QuotaGate(primary: spy, meter: m)
        let out = try await gate.translate("hello", from: "en", to: "zh-TW")   // 5 scalars
        XCTAssertEqual(out, "你好")
        XCTAssertTrue(spy.called)
        XCTAssertEqual(m.used, 5)
    }

    func testOverCapThrowsWithoutCallingPrimary() async {
        let m = meter()
        m.record(490_000)                                   // at the cap
        let spy = SpyEngine(.success("x"))
        let gate = QuotaGate(primary: spy, meter: m)
        await XCTAssertThrowsErrorAsync(try await gate.translate("hi", from: "en", to: "zh-TW")) {
            XCTAssertEqual($0 as? TranslationError, .quotaExceeded)
        }
        XCTAssertFalse(spy.called)
        XCTAssertEqual(m.used, 490_000)                     // unchanged
    }

    func testPrimaryErrorPropagatesAndRecordsNothing() async {
        struct Boom: Error {}
        let m = meter()
        let spy = SpyEngine(.failure(Boom()))
        let gate = QuotaGate(primary: spy, meter: m)
        await XCTAssertThrowsErrorAsync(try await gate.translate("hello", from: "en", to: "zh-TW")) { _ in }
        XCTAssertEqual(m.used, 0)                           // not recorded on failure
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `swift test --package-path TranslationCore 2>&1 | tail -5`
Expected: compile failure — `QuotaGate` doesn't exist.

- [ ] **Step 3: Implement QuotaGate.swift**

```swift
import Foundation

/// Wraps a primary engine (Google) with the monthly free-tier cap. Under the
/// cap it translates and records the characters; over it, it throws
/// `.quotaExceeded` so `FallbackChain` uses the (free) Apple fallback — the user
/// can never be charged for over-quota Google usage.
public final class QuotaGate: TranslationEngine {
    private let primary: TranslationEngine
    private let meter: UsageMeter

    public init(primary: TranslationEngine, meter: UsageMeter) {
        self.primary = primary
        self.meter = meter
    }

    public func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let chars = text.unicodeScalars.count
        guard meter.canUseGoogle(adding: chars) else { throw TranslationError.quotaExceeded }
        let result = try await primary.translate(text, from: source, to: target)   // network error propagates
        meter.record(chars)                                                        // only on success
        return result
    }
}
```

- [ ] **Step 4: Run tests + full suite**

Run: `swift test --package-path TranslationCore 2>&1 | grep -E "Executed [0-9]+ tests|failed" | tail -1`
Expected: `Executed 48 tests, with 0 failures` (41 + 4 UsageMeter + 3 QuotaGate).

- [ ] **Step 5: Commit**

```bash
git add TranslationCore/Sources/TranslationCore/QuotaGate.swift TranslationCore/Tests/TranslationCoreTests/QuotaGateTests.swift
git commit -m "feat: QuotaGate — route over-cap translations to the Apple fallback"
```

---

### Task 3: Wire meter + gate into the app + notification

**Files:**
- Create: `TypeTranslatorApp/Sources/TypeTranslatorBar/Metering.swift`
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift`

**Interfaces:**
- Consumes: `UsageMeter`, `UserDefaultsUsageStore`, `QuotaGate`, `TranslationError.quotaExceeded`.
- Produces: `@MainActor enum MeterAccess { static var meter: UsageMeter?; static func resetDateString() -> String }`; `AppDelegate.handleQuotaReached()`.

- [ ] **Step 1: Create Metering.swift**

```swift
import Foundation
import TranslationCore

/// Shared access to the usage meter (set by AppDelegate) plus the shared
/// month-reset date string used by the menu and Settings.
@MainActor
enum MeterAccess {
    static var meter: UsageMeter?

    /// Current month's Gregorian key, e.g. "2026-7".
    static func currentMonthKey() -> String {
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
```

- [ ] **Step 2: Build the meter + gate into the engine chain**

In `AppDelegate.swift`, add `import UserNotifications` at the top and a property `private var usageMeter: UsageMeter?` near the other properties. Then replace the engine-construction block in `applicationDidFinishLaunching`:

```swift
let secrets = KeychainSecretStore()
let http = URLSessionHTTPClient()
let google = GoogleEngine(secrets: secrets, http: http)
let meter = UsageMeter(store: UserDefaultsUsageStore(),
                       month: { MeterAccess.currentMonthKey() })
usageMeter = meter
MeterAccess.meter = meter
let gated = QuotaGate(primary: google, meter: meter)
let flag = FallbackFlag()
let engine: TranslationEngine
if #available(macOS 15, *) {
    let chain = FallbackChain(primary: gated, fallback: AppleEngine())
    chain.onFallback = { [weak self] error in
        flag.value = true
        if error == .quotaExceeded { Task { @MainActor in self?.handleQuotaReached() } }
    }
    engine = chain
} else {
    engine = gated   // macOS 14: no Apple fallback; over-cap fails closed (never charged)
}
service = TranslateService(engine: engine, fallbackFlag: flag)
```

- [ ] **Step 3: Request notification permission + add the quota handler**

Add near the end of `applicationDidFinishLaunching` (e.g. after `networkMonitor.start()`):

```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
```

Add the handler method to `AppDelegate`:

```swift
/// First time the monthly cap is hit, tell the user we've switched to Apple.
private func handleQuotaReached() {
    guard let meter = usageMeter, !meter.hasNotified else { return }
    meter.markNotified()
    updateUsageDisplay()   // added in Task 4; safe no-op-ish until then

    let content = UNMutableNotificationContent()
    content.title = "Google free limit reached"
    content.body = "Using Apple on-device translation until \(MeterAccess.resetDateString())."
    let request = UNNotificationRequest(identifier: "quota.reached", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}
```

Note: `updateUsageDisplay()` is introduced in Task 4. To keep this task compiling on its own, add a temporary empty stub now and flesh it out in Task 4:

```swift
private func updateUsageDisplay() {}   // TEMP — implemented in Task 4
```

- [ ] **Step 4: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -3`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 5: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/Metering.swift TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift
git commit -m "feat: wire UsageMeter + QuotaGate into the engine chain + quota notification"
```

---

### Task 4: Menu usage row

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift`

**Interfaces:**
- Produces: a view-based usage row in the menu, refreshed by `updateUsageDisplay()` after each translation and on menu open.

- [ ] **Step 1: Add properties + the usage view builder**

In `AppDelegate.swift`, add properties:

```swift
private var usageLabel: NSTextField!
private var usageBar: NSProgressIndicator!
```

Add the builder (near `buildEngineStatusView`):

```swift
private func buildUsageView() -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 42))

    usageLabel = NSTextField(labelWithString: "")
    usageLabel.font = .systemFont(ofSize: 12)
    usageLabel.textColor = .secondaryLabelColor
    usageLabel.translatesAutoresizingMaskIntoConstraints = false

    usageBar = NSProgressIndicator()
    usageBar.isIndeterminate = false
    usageBar.style = .bar
    usageBar.controlSize = .small
    usageBar.minValue = 0
    usageBar.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(usageLabel)
    container.addSubview(usageBar)
    NSLayoutConstraint.activate([
        usageLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
        usageLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
        usageLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        usageBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
        usageBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        usageBar.topAnchor.constraint(equalTo: usageLabel.bottomAnchor, constant: 4),
    ])
    return container
}
```

- [ ] **Step 2: Replace the temporary updateUsageDisplay stub with the real implementation**

Replace `private func updateUsageDisplay() {}` with:

```swift
private func updateUsageDisplay() {
    guard let meter = usageMeter else { return }
    let used = meter.used
    usageBar?.maxValue = Double(meter.limit)
    usageBar?.doubleValue = Double(min(used, meter.limit))
    if used >= meter.cap {
        usageLabel?.stringValue = "Free limit reached — on Apple until \(MeterAccess.resetDateString())"
    } else {
        usageLabel?.stringValue = "Usage  ≈\(shortCount(used)) / \(shortCount(meter.limit))"
    }
}

/// Compact character count, e.g. 42300 → "42k".
private func shortCount(_ n: Int) -> String {
    n >= 1000 ? "\(n / 1000)k" : "\(n)"
}
```

- [ ] **Step 3: Add the usage row to the menu**

In the menu construction, right after the engine-status item block (the `engineStatusItem` + its trailing `menu.addItem(.separator())`), insert:

```swift
let usageItem = NSMenuItem()
usageItem.view = buildUsageView()
menu.addItem(usageItem)
menu.addItem(.separator())
```

- [ ] **Step 4: Refresh the display after translations, on menu open, and at launch**

In the `service.onEngineUsed` closure, add `self?.updateUsageDisplay()` alongside the existing lines. In `menuWillOpen` add `updateUsageDisplay()` next to `updateEngineStatus()`. At the end of `applicationDidFinishLaunching` (after `updateEngineStatus()`), add `updateUsageDisplay()`.

- [ ] **Step 5: Build + manual check**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1` → `Build complete!`, zero warnings.
Then `./scripts/build-bar.sh && killall TypeTranslatorBar 2>/dev/null; open "build/Type Translator.app"`. The menu shows a "Usage ≈… / 500k" row with a bar; it increases after Google translations.

- [ ] **Step 6: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift
git commit -m "feat: menu usage row (characters this month + progress bar)"
```

---

### Task 5: Settings "Usage" section

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/SettingsWindow.swift`

**Interfaces:**
- Consumes: `MeterAccess.meter`, `MeterAccess.resetDateString()`.

- [ ] **Step 1: Add the Usage section**

In `SettingsView`'s `Form`, add a section (place it after "Translation"):

```swift
Section("Usage") {
    Text(usageSummary).font(.callout)
    Button("View exact usage in Google Cloud →") {
        if let url = URL(string: "https://console.cloud.google.com/apis/api/translate.googleapis.com/metrics") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

Add the computed summary to `SettingsView`:

```swift
private var usageSummary: String {
    guard let meter = MeterAccess.meter else { return "Usage tracking unavailable." }
    let used = meter.used
    if used >= meter.cap {
        return "Free limit reached (\(used.formatted()) / \(meter.limit.formatted())). "
             + "Using Apple on-device until \(MeterAccess.resetDateString())."
    }
    return "≈\(used.formatted()) / \(meter.limit.formatted()) characters this month · "
         + "Resets \(MeterAccess.resetDateString())."
}
```

- [ ] **Step 2: Build + manual check**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1` → `Build complete!`, zero warnings.
Then rebuild/relaunch and open Settings: a "Usage" section shows the count + reset date and a working "View exact usage in Google Cloud →" button.

- [ ] **Step 3: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/SettingsWindow.swift
git commit -m "feat: Settings Usage section + Google Cloud metrics link"
```

---

### Task 6: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document usage tracking**

In `README.md`, add a short note under Usage/features: the app tracks Google's free-tier characters (500k/month), shows the count in the menu and Settings, and automatically switches to Apple's on-device engine before you'd be charged — notifying you once when it does. It resets each calendar month.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document monthly usage tracking + auto-protect"
```

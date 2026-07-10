# Monthly Usage Counter + Auto-Protect — Design

**Date:** 2026-07-10
**Status:** Approved (design)

## Goal

Track how much of Google's free tier (500,000 characters/month) the user has
consumed, show it, and **guarantee they are never charged**: when a translation
would push usage past a safety cap, route it to Apple's on-device engine instead
of Google. Notify once when that happens; reset monthly.

## Behavior

### Counting

- Each **successful Google** translation adds its input character count to a
  monthly running total. Characters are counted as **Unicode scalars**
  (`text.unicodeScalars.count`), matching how Google bills (code points,
  whitespace included).
- Apple translations and failed translations are **not** counted — they don't
  consume Google quota.
- Both Compose and Read count (both hit Google when online and under the cap).

### Auto-protect (stay free)

- Free limit: **500,000**. Safety cap: **490,000** (a margin below the limit,
  since the local count can differ slightly from Google's).
- Before a translation, if using Google would exceed the cap
  (`used + inputChars > cap`), Google is skipped and **Apple on-device** handles
  it — reusing the existing `FallbackChain` fallback path.
- Once the cap is reached, every subsequent translation uses Apple until the
  month resets. The user can never cross into paid Google usage.

### Notification (once per month)

- The first time the cap is reached in a month, post a macOS user notification:
  *"Google free limit reached — using Apple on-device until <reset date>."*
- The app requests notification authorization once. If denied, the menu still
  shows the capped state (graceful degradation).

### Display

- **Menu:** a row showing usage — *"Usage  ≈42k / 500k"* with a small progress
  bar. When capped: *"Free limit reached — on Apple until Aug 1."* Updates after
  each translation and when the menu opens.
- **Settings:** a "Usage" section showing the count, the reset date, and a
  **"View exact usage in Google Cloud →"** button that opens
  `https://console.cloud.google.com/apis/api/translate.googleapis.com/metrics`.

### Reset

- Aligns to the **calendar month** (a `"YYYY-MM"` key). When the current month
  differs from the stored month, the count resets to 0 and the once-per-month
  notification re-arms.

## Architecture

The metering logic is money-sensitive, so it lives in `TranslationCore` with
injectable dependencies and unit tests; display and notifications stay in the app.

### `UsageMeter` (TranslationCore)

Thread-safe (`@unchecked Sendable`, lock-protected) counter, persisted through an
injectable store and an injectable "current month" so it can be unit-tested
without real time or `UserDefaults`.

```
public protocol UsageStore: Sendable {   // get/set the three persisted values
    func int(_ key: String) -> Int
    func setInt(_ v: Int, _ key: String)
    func string(_ key: String) -> String?
    func setString(_ v: String?, _ key: String)
    func bool(_ key: String) -> Bool
    func setBool(_ v: Bool, _ key: String)
}

public final class UsageMeter: @unchecked Sendable {
    public let limit = 500_000
    public let cap = 490_000
    public init(store: UsageStore, month: @escaping @Sendable () -> String)
    public var used: Int { get }                 // rolls over if the month changed
    public func canUseGoogle(adding chars: Int) -> Bool   // used + chars <= cap
    public func record(_ chars: Int)             // add to this month's total
    public var hasNotified: Bool { get }
    public func markNotified()
}
```

- Every accessor first checks the stored month against `month()`; on change it
  zeroes `used` and clears `hasNotified` before returning.
- A `UserDefaultsUsageStore` provides the production implementation.

### `QuotaGate` (TranslationCore)

A `TranslationEngine` wrapping the Google engine + the meter:

```
public final class QuotaGate: TranslationEngine {
    public init(primary: TranslationEngine, meter: UsageMeter)
    public func translate(_ text: String, from: String, to: String) async throws -> String {
        let chars = text.unicodeScalars.count
        guard meter.canUseGoogle(adding: chars) else { throw TranslationError.quotaExceeded }
        let result = try await primary.translate(text, from: from, to: to)  // network error propagates
        meter.record(chars)                                                 // only on success
        return result
    }
}
```

- Over the cap → throws `.quotaExceeded`, which `FallbackChain` treats like any
  error and falls back to Apple. Under the cap → translates and records only on
  success (a Google network failure propagates and isn't counted).

### App wiring (TypeTranslatorBar)

- Build once: `let meter = UsageMeter(store: UserDefaultsUsageStore(), month: …)`;
  `FallbackChain(primary: QuotaGate(primary: google, meter: meter), fallback: apple)`.
- Keep the `meter` reference for the menu/Settings display.
- Notification: the chain's `onFallback` already fires on fallback. When the
  error is `.quotaExceeded` and `!meter.hasNotified`, post the notification and
  call `meter.markNotified()`. (Google's own 429 → `.quotaExceeded` triggers the
  same path, which is correct — the limit was hit either way.)
- Menu: a view-based usage row (like the engine-status row), refreshed from the
  meter after each translation and on `menuWillOpen`.
- Settings: a "Usage" section (text + reset date + the Google Cloud link).

## Components

- `TranslationCore`: `UsageStore` (protocol) + `UserDefaultsUsageStore`,
  `UsageMeter`, `QuotaGate` — with unit tests.
- App: engine-chain wiring in `AppDelegate`; a usage menu row + its refresh; a
  Settings "Usage" section; notification request + one-time post.

## Testing

Unit tests (TranslationCore):
- `UsageMeter`: `record` accumulates; `canUseGoogle` false once `used + chars`
  exceeds `cap`; month rollover zeroes `used` and re-arms `hasNotified`;
  `markNotified`/`hasNotified` behave within a month.
- `QuotaGate`: under cap delegates to the primary and records the scalar count;
  over cap throws `.quotaExceeded` **without** calling the primary; a primary
  network error propagates and records nothing.

Live-in-app: the menu/Settings usage display updates; the notification fires once
when the cap is reached; the reset date reads correctly.

## Out of scope

- Fetching exact usage from Google (requires OAuth/service-account + Cloud
  Monitoring); the console link covers the authoritative figure instead.
- Per-day or rolling-window limits (calendar month only).
- Tracking Apple/offline usage (unmetered — it's free).

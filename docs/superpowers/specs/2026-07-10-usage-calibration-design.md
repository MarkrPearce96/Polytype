# Usage Calibration — Design

**Date:** 2026-07-10
**Status:** Approved (design)

## Goal

Let the user set the counter to their **exact** current Google usage and their
**actual** renewal date, so the local estimate matches their real account. From
then on it self-manages: the count zeroes on the renewal date, which rolls
forward one month automatically.

## Behavior

- In Settings' "Usage" section, a calibration control:
  - **Current usage** — a number field (this cycle's exact character count, read
    from the Google console).
  - **Renews on** — a date picker (the next reset date).
  - **Update** button.
- **Update** sets the counter to the entered number and the reset to the chosen
  date.
- The reset date **recurs monthly**: each time `now` reaches it, the count zeroes,
  the one-time notification re-arms, and the reset date advances one month (Aug 3
  → Sep 3 → …). Set once, then hands-off.
- The menu row, Settings summary, and the auto-protect cap all reflect the
  calibrated number immediately.
- **Uncalibrated default:** the reset date defaults to the **first of next month**
  — matching today's calendar-month behavior, so it works out of the box.

## Reset-model change

Today `UsageMeter` resets when a `"year-month"` key changes. This replaces that
with a stored **next-reset `Date`** that advances monthly, which is what makes a
custom renewal day possible.

### `UsageMeter` (TranslationCore) changes

- Replace the injected `month: () -> String` with an injected clock
  `now: () -> Date` (defaults to `{ Date() }`; injectable for tests).
- Persist a `nextResetDate` (via new `double`/`setDouble` on `UsageStore`,
  stored as `timeIntervalSinceReferenceDate`).
- `rolloverIfNeeded()` (caller holds the lock): let `next` be the stored reset
  date, or — if unset — the **first of next month** computed from `now()`. If
  `now() >= next`, zero `used`, clear `notified`, and advance `next` by one
  Gregorian month repeatedly until it's in the future, then store it.
- Add:
  - `public var nextResetDate: Date` — the current cycle's reset date (for display).
  - `public func calibrate(used chars: Int, nextReset date: Date)` — sets `used`
    = `chars`, stores `nextReset` = `date`, and clears `notified` (so the cap
    notification can fire again this cycle).
- `used`, `canUseGoogle(adding:)`, `record(_:)`, `hasNotified`, `markNotified()`
  keep their signatures; each still rolls over under the lock first.
- All money-critical guarantees are unchanged: `canUseGoogle`/`record` still gate
  and count exactly as before; only the reset trigger changes from month-key to
  date.

### `UsageStore`

- Add `func double(_ key: String) -> Double` and
  `func setDouble(_ value: Double, _ key: String)`; implement in
  `UserDefaultsUsageStore` via `UserDefaults.double(forKey:)` / `set(_:forKey:)`.

## App changes

- **`Metering.swift`:** `MeterAccess.currentMonthKey()` is removed (no longer
  needed). `resetDateString()` now formats `MeterAccess.meter?.nextResetDate`
  (e.g. "Aug 3") instead of computing the calendar next-month itself. Build the
  meter with `now: { Date() }`.
- **`AppDelegate.swift`:** construct the meter with the `now` clock;
  `updateUsageDisplay()` and the notification's reset text use the meter's
  `nextResetDate` via `MeterAccess.resetDateString()` (already the case).
- **`SettingsWindow.swift`:** in the "Usage" section, add the calibration row —
  a numeric `TextField` ("Current usage"), a `DatePicker` ("Renews on",
  `.compact`, date only, pre-filled from `meter.nextResetDate`), and an "Update"
  button that parses the number (ignore if not a non-negative integer) and calls
  `meter.calibrate(used:nextReset:)`, then refreshes the summary.

## Components

- `TranslationCore`: `UsageStore` (+`double`/`setDouble`), `UserDefaultsUsageStore`,
  `UsageMeter` (clock + `nextResetDate` + `calibrate`) — with unit tests.
- App: `Metering.swift` (reset-date formatting), `AppDelegate` (meter
  construction + display), `SettingsWindow` (calibration control).

## Testing

Unit tests (TranslationCore), replacing the month-key tests:
- `calibrate` sets `used` and `nextResetDate`, and clears `notified`.
- No reset while `now < nextResetDate`; `used`/`hasNotified` persist.
- At/after `nextResetDate`: `used` → 0, `hasNotified` re-armed, `nextResetDate`
  advanced exactly one month.
- Long gap (now several months past a set reset date) advances to the first
  future monthly boundary (not just +1).
- Uncalibrated default reset date is the first of next month relative to `now`.
- `canUseGoogle`/`record`/cap boundary still behave (regression).

Live-in-app: entering a usage number + date in Settings updates the menu row and
summary; the reset date displays correctly; the auto-protect cap uses the
calibrated number.

## Out of scope

- Fetching the exact number automatically from Google (still needs OAuth).
- Sub-day / time-of-day reset precision (date granularity only).
- Validating the entered number against Google (it's user-provided truth).

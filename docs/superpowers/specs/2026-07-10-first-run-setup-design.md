# First-Run Setup Wizard — Design

**Date:** 2026-07-10
**Status:** Approved (design; mockup reviewed)

## Goal

Guide a new user through the essential setup on first launch — Accessibility
permission, translation key, language, and shortcuts — so the app works without
them having to discover each piece from the menu. Existing users never see it.

## When it appears

- **First launch only:** shown when a `setupCompleted` flag (UserDefaults, default
  `false`) is not set. Finishing the wizard sets the flag; it never auto-shows again.
- **Re-openable:** a menu item ("Setup Assistant…") reopens it anytime.
- **Skippable, shows once:** the window is closable and steps can be skipped. The
  `setupCompleted` flag is set on the **first dismissal** — whether the user
  finishes (step 6) or closes the window early — so it never nags. If they closed
  early, they reopen it from the menu.

## The window

A single `NSWindow` (titled, closable; ~460×540, matching the mockup) hosting a
SwiftUI wizard with a step indicator (dots) and Back / Next-style navigation.
Reuses the app's identity: the blue→violet globe, system font, native controls.

## Steps (6)

1. **Welcome** — the globe, "Welcome to Type Translator", one line on what it
   does. Button: **Get started**.

2. **Grant Accessibility** — explains the hotkey needs permission to read/replace
   text. A button opens System Settings ▸ Privacy & Security ▸ Accessibility. A
   live status pill polls `AXIsProcessTrusted()` (~1s timer while on this step):
   "Waiting for permission…" → green "Access granted". **Next is disabled until
   granted**, so the user can't proceed to a dead hotkey.

3. **Add your translation key** — a `SecureField` for a Google Cloud Translation
   key (saved to the Keychain under `googleKeyName`), a "Get a free key →" link to
   the console, and the free-tier note (500k/month). A **Skip** action proceeds
   without a key (Apple on-device only).

4. **Choose your language** — a picker for the Compose target
   (`LanguagePrefs.composeTargetCode`, from `Languages.all`, default `zh-TW`). Note
   that Read auto-detects. No hotkey references here (shortcuts are their own step).

5. **Choose your shortcuts** — two `HotkeyRecorder` controls (reused from
   Settings): Compose (default ⌥⌘T) and Read (default ⌥⌘R), each calling
   `HotkeyAccess.compose`/`read`'s `update(...)`. Defaults are pre-filled so most
   users just continue.

6. **You're all set** — a short recap of what the (chosen) Compose/Read shortcuts
   do, a **Launch at login** toggle (`LoginItem`), and **Start translating**, which
   sets `setupCompleted` and closes the window.

## Behavior

- Navigation: `Back` / `Next` (or the step's primary action). The step index is
  SwiftUI `@State`.
- Accessibility gate: `Next` on step 2 is enabled only when `AXIsProcessTrusted()`
  returns true; the polling timer stops when leaving the step.
- `setupCompleted = true` is set when the window is first dismissed (the step-6
  **Start translating** button, or closing the window from any step).
- Reopening from the menu shows the same wizard from step 1.

## Components

- Create `SetupWizard.swift` (app target): the SwiftUI `SetupView` (6 step
  subviews + dots + navigation), a `SetupWindowController` (owns the single
  window, like `SettingsWindowController`), and the `setupCompleted` flag accessor.
- `AppDelegate.swift`: at the end of launch, if `!setupCompleted`, show the wizard;
  add a "Setup Assistant…" menu item that reopens it.
- Reuses (no changes): `HotkeyRecorder`/`HotkeyAccess`, `LanguagePrefs`/`Languages`,
  `KeychainSecretStore`/`googleKeyName`, `LoginItem`, `AXIsProcessTrustedWithOptions`.

## Testing

Live-in-app (the wizard is SwiftUI/AppKit UI, no unit target for the app):
- First launch (with `setupCompleted` cleared) shows the wizard; finishing sets the
  flag; relaunch doesn't reshow it; the menu item reopens it.
- Accessibility step: `Next` stays disabled until permission is granted, then
  enables; the pill flips to green.
- Key/language/shortcuts entered in the wizard persist (Keychain / `LanguagePrefs` /
  hotkey combos) and match what Settings shows.

## Out of scope

- A separate onboarding for each future feature (usage, calibration) — those stay
  in Settings.
- Migrating existing users through the wizard (only genuinely-new installs see it).
- Localizing the wizard copy.

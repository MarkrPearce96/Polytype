# More Languages — Design

**Date:** 2026-07-10
**Status:** Approved (design)

## Goal

Let the user translate to/from more than just Taiwanese Mandarin, while keeping
English as their home language. Compose (⌥⌘T) translates English → a chosen
target language; Read (⌥⌘R) translates a foreign selection → English, with the
source either auto-detected (online) or a chosen language (works offline).

## Home-language model

English is always the user's side. Only the *other* language varies:
- **Compose:** English → *target language* (user-selected, default Traditional Chinese)
- **Read:** *source language* → English (auto-detected by default, or user-selected)

Arbitrary pairs (foreign → foreign, no English) are explicitly out of scope.

## Curated language list

Baked into the app (a one-line change adds more later). Each entry is a
`(code, displayName)` pair; the code is the exact code the translation engines
use:

| Display | Code |
|---------|------|
| 繁體中文 (Chinese, Traditional) | `zh-TW` |
| 简体中文 (Chinese, Simplified) | `zh-CN` |
| 日本語 (Japanese) | `ja` |
| 한국어 (Korean) | `ko` |
| Español (Spanish) | `es` |
| Français (French) | `fr` |
| Deutsch (German) | `de` |
| ไทย (Thai) | `th` |
| Tiếng Việt (Vietnamese) | `vi` |

## Language selection (menu bar)

Two independent submenus in the globe menu, each showing a checkmark on the
current selection and persisting the choice in `UserDefaults`:

- **Compose language ▸** — the target for ⌥⌘T. Options: the curated list.
  Default `zh-TW`. Persisted as `composeTargetCode`. Selecting one updates the
  compose menu-item label (e.g. "Translate what I typed → 日本語").
- **Read language ▸** — the source for ⌥⌘R. Options: **Auto-detect** (default)
  plus the curated list. Persisted as `readSourceCode` (the sentinel `"auto"`
  for auto-detect). Selecting one updates the read menu-item label
  (e.g. "Read selection (Auto-detect)" / "Read selection (日本語)").

### Online vs offline Read (the hybrid)

- **Auto-detect** (default): Google detects the language and translates to
  English. Requires internet (Apple's on-device engine cannot auto-detect). If
  offline while set to Auto-detect, Read fails gracefully with a popup hint to
  pick a Read language.
- **A specific language**: translates that language → English. Works online
  (Google) **and** offline (Apple on-device).

So the effortless default is Auto-detect when online; if the user is ever
offline, they pick the specific language from the menu and Read keeps working.

## Engine changes

The `TranslationEngine.translate(_:from:to:)` signature already carries source
and target. Changes:

- **GoogleEngine:** stop forcing every `zh*` code to `zh-TW`; pass the exact
  `target`/`source` codes through (so Traditional `zh-TW` and Simplified `zh-CN`
  are distinct). When `source == "auto"`, omit the `source` form field entirely
  so Google auto-detects. Existing tests that use exact codes (`en`, `zh-TW`)
  keep passing.
- **AppleEngine:** pass the codes through to `Locale.Language(identifier:)`.
  When `source == "auto"`, throw a `TranslationError` (it cannot auto-detect) —
  this is what makes offline Auto-detect fail gracefully rather than mistranslate.
- **DeepLEngine:** pass codes through (uppercased, with the existing Chinese
  special-casing). DeepL is not in the default chain, but keep it correct.

## Call sites

- **Compose** (`TranslateService`): `translate(text, from: "en", to: composeTargetCode)`.
- **Read** (`TranslateService`): `translate(text, from: readSourceCode, to: "en")`
  where `readSourceCode` is `"auto"` or a language code.

Both read the current selection from a shared, UserDefaults-backed preferences
holder rather than hardcoded constants.

## Components

- `Language.swift` (app target): a `Language` struct (`code`, `name`) and
  `Languages.all` (the curated list). Read options add a leading
  "Auto-detect" (`code == "auto"`).
- `LanguagePrefs` (app target): UserDefaults-backed current `composeTargetCode`
  (default `zh-TW`) and `readSourceCode` (default `auto`), reachable from both
  the menu (AppDelegate) and `TranslateService` (like the existing `HotkeyAccess`
  pattern).
- `TranslateService`: compose/read use `LanguagePrefs` instead of the hardcoded
  `zh-TW`/`en` constants; the read failure popup mentions picking a Read language
  when offline.
- `AppDelegate`: builds the two submenus, handles selection (update prefs,
  checkmarks, and the two menu-item labels), and shows the current selections in
  the compose/read menu item titles.
- `GoogleEngine` / `AppleEngine` / `DeepLEngine`: the code-mapping / auto-detect
  changes above.

## Testing

Unit tests (TranslationCore):
- Google: `translate(from: "auto", ...)` omits the `source` form field; a
  non-Chinese target (e.g. `ja`) is sent verbatim; `zh-TW` and `zh-CN` are sent
  distinctly (not both collapsed to `zh-TW`).
- Apple: `translate(from: "auto", ...)` throws a `TranslationError` (guarded so
  the `#else` stub and the macOS-15 path agree on the contract) — verified by
  reading, since AppleEngine's session path needs a live app; the `"auto"` guard
  itself is a plain early check that can be unit-tested without a session.
- Existing engine tests updated where the zh-forcing removal changes an
  assertion (none expected, since they use exact codes).

Live-in-app verification: the two submenus switch languages, persist across
relaunch, and Compose/Read use the selected languages; offline Read with a
specific language works via Apple.

## Out of scope

- Arbitrary foreign→foreign pairs (English is always one side).
- A self-managed / searchable full language list (curated list only).
- Auto-detect for the Apple on-device engine (not supported by the framework).
- Showing the detected source language in the Read popup.

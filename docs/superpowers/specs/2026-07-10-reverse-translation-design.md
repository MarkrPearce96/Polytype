# Reverse (Read) Translation — Design

**Date:** 2026-07-10
**Status:** Approved (design)

## Goal

Add a second, read-only translation direction to the menu-bar app: **Taiwanese
Mandarin → English**, for understanding incoming Chinese text (messages, web
pages, PDFs, anywhere). The existing compose direction (English → Mandarin,
replace-in-place) is unchanged.

## Why read-only

Reverse translation targets text the user does not own — a friend's chat
message, a published web page. That text is not editable and must not be
overwritten. So the reverse flow *shows* the translation in a popup rather than
pasting it. This also means the user selects the specific text first: among a
full page or conversation, only the user can indicate which passage to read.

## Interaction model

Two purpose-built, independently-customizable global hotkeys:

| Hotkey | Name | Direction | Behavior |
|--------|------|-----------|----------|
| ⌥⌘T (existing) | Compose | English → zh-TW | Copy selection (or select-all in an empty-ish field) → translate → paste in place |
| ⌥⌘R (new, default) | Read | zh-TW → English | Copy current selection → translate → show popup near cursor; nothing pasted |

Read flow, step by step:
1. User selects Chinese text and presses the Read hotkey.
2. App saves the clipboard, synthesizes ⌘C to copy the selection.
3. If the clipboard did not change (nothing was selected) → `NSSound.beep()`, no
   popup, clipboard restored. (No select-all fallback: on a web page or chat that
   would grab everything.)
4. Otherwise translate zh-TW → English via the engine chain.
5. Show the English in a popup near the mouse cursor. Restore the clipboard.

## Bidirectional engine change

Today engines are effectively hardcoded English → zh-TW. Generalize to carry a
source language.

- **Protocol:** change `TranslationEngine.translate` from
  `translate(_ english: String, to target: String)` to
  `translate(_ text: String, from source: String, to target: String)`.
- **GoogleEngine:** send `source` and `target` form fields (already supports both
  directions). Map any `zh*` code to `zh-TW`; pass `en` through.
- **AppleEngine:** build `TranslationSession.Configuration` from the given
  source/target `Locale.Language`. The reverse pair (zh-Hant → en) may prompt a
  one-time language-pack download, same mechanism as the forward pair.
- **DeepLEngine:** send `source_lang` from the source (kept for completeness even
  though DeepL is not in the default chain).
- **FallbackChain:** pass source/target straight through to both engines.

Call sites:
- Compose: `translate(text, from: "en", to: "zh-TW")`
- Read: `translate(text, from: "zh-TW", to: "en")`

## The popup

- A borderless floating panel (`NSPanel`, non-activating) showing the English
  text: rounded corners, subtle shadow, theme-aware colors, comfortable padding,
  wraps and caps width for long passages.
- Positioned near the mouse cursor, then nudged to stay fully on the active
  screen.
- While the translation is in flight it shows "…"; then the result replaces it.
- Dismissal: **Esc**, a click on the popup, clicking elsewhere (resigns key /
  loses focus), or an auto-dismiss timeout (~8s) as a fallback. Showing a new
  popup replaces any existing one.

## Error handling

- Translation throws / offline with no Apple pack → popup shows a short message
  ("Couldn't translate — check connection or API key.") rather than nothing.
- The same busy-guard + 25s watchdog used for compose applies, so a stalled read
  can never wedge the app.
- Empty or whitespace-only selection → treated as "nothing selected" (beep).

## Components

- `TranslationEngine` (protocol) + `GoogleEngine` / `AppleEngine` / `DeepLEngine`
  / `FallbackChain` — signature change to add `source`.
- `HotkeyController` — generalized from one hotkey to two named hotkeys
  (compose, read), each with its own persisted combo, registration, and Settings
  recorder. Default read combo ⌥⌘R.
- `TranslateService` — add a read path (`translateSelectionToPopup`) alongside
  the existing compose path; shared copy/clipboard/watchdog helpers.
- `ResultPopup` (new) — the floating panel: show(text, atCursor), dismiss.
- `AppDelegate` — wire the second hotkey; menu shows both shortcuts.
- `SettingsView` — a second recorder row for the Read shortcut.

## Testing

- Unit tests (TranslationCore):
  - Google reverse request sends `source=zh-TW`, `target=en`; forward still
    `source=en`, `target=zh-TW`.
  - DeepL reverse sends the expected `source_lang`/`target_lang`.
  - Existing engine tests updated to the new signature.
  - FallbackChain forwards source/target to both engines.
- Live-in-app verification (no automated UI test): Read hotkey on selected
  Chinese shows the popup; beep on empty selection; popup dismissal paths.

## Out of scope

- Auto-detecting language / a single "smart" hotkey (explicit directions are
  clearer and predictable).
- Translating a whole page at once (browsers already do this).
- More than the two languages (English ↔ Taiwanese Mandarin); broader
  multi-language support is a separate future project.

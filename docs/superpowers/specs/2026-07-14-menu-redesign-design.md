# Menu Redesign — Direction-First Dropdown

**Date:** 2026-07-14
**Status:** Approved (design; mockup reviewed — "Option B" + status "Variant 2")

## Goal

Rebuild the menu-bar dropdown around the two things it actually communicates:
which direction each shortcut translates, and whether the engine/free tier is
healthy. The menu today is **13 rows + 5 separators** grown organically; the new
one is **7 rows + 2 separators**.

## What the menu is for

Translation is triggered by the **hotkeys**, not the menu. The menu is therefore
**status + configuration**: it shows both directions (with their shortcut as a
reminder), lets you change either language, reports engine/usage, and reaches
Settings/Setup/Quit. The clickable "Translate what I typed" / "Read selection"
action rows are **removed** — a deliberate, approved trade (the shortcut is
printed on each card, and the setup wizard teaches them).

## Structure (top to bottom)

1. **Compose card** — view-based item; its submenu is the existing compose
   language list.
   - Line 1: `COMPOSE` (uppercase caption) · right-aligned `⌥⌘T` + submenu chevron
   - Line 2: `English → 繁體中文` (14pt semibold)
2. **Read card** — view-based item; submenu is the existing read language list.
   - Line 1: `READ` · right-aligned `⌥⌘R` + chevron
   - Line 2: `Auto-detect → English`
3. separator
4. **Status row** — view-based, non-interactive ("Variant 2", stacked):
   - Line 1: colored dot · engine/state text (flexible) · usage count (right, tabular)
   - Line 2: full-width thin progress bar
5. separator
6. `Settings…` (⌘,) · `Setup Assistant…` · `Quit` (⌘Q) — stock rows

**Removed:** the identity header (the menu-bar icon is the identity), both action
rows, the two standalone "Compose language"/"Read language" rows (the cards own
those submenus now), and the separate engine and usage rows (merged into 4).

Menu width stays ~292pt.

## Direction cards

Each card is a custom `NSView` inside an `NSMenuItem`, so it must **draw its own
highlight** — AppKit doesn't highlight custom views. On highlight the card fills
with the system accent and its text flips to white.

- Highlight source of truth: `enclosingMenuItem?.isHighlighted`, read in `draw(_:)`.
- An `NSTrackingArea` (`.mouseEnteredAndExited`, `.activeAlways`, `.inVisibleRect`)
  sets `needsDisplay = true` on enter/exit so the redraw is reliable.
- The card's `NSMenuItem.submenu` is the language menu, so hovering opens it and
  the existing checkmark logic keeps working unchanged.
- Direction text uses the existing `shortLang(_:)` (native name without the
  trailing "(English name)"), e.g. `English → 繁體中文`, `Auto-detect → English`.

## Status row states

One merged updater replaces `updateEngineStatus()` + `updateUsageDisplay()`. The
branches must be evaluated **in this exact order** — it mirrors the existing
`updateEngineStatus()` logic, with the capped check (from `updateUsageDisplay()`)
taking precedence over everything:

1. **Capped** (`meter.hasNotified || used >= meter.cap`) → gray dot ·
   `Free limit reached — on Apple until <date>` · **count hidden** · bar full, gray.
2. **`lastEngineUsed == "failed"`** → orange dot ·
   `Translation failed` when `networkMonitor.isOnline`, else `No connection` ·
   count · progress bar.
3. **`lastEngineUsed == "apple"`** → gray dot · `Apple on-device` · count · progress.
4. **Otherwise** (`"google"`, or nothing run yet), in this order:
   - no API key → gray dot · `Apple on-device`
   - not online → orange dot · `No connection`
   - else → green dot · `Google — active`
   …each with count · progress bar.

Count format is the existing `"≈42k / 500k"` shortening; the bar is
`used / limit`.

The capped row deliberately gives its whole width to the message — that's the one
state that must never truncate, since it's how the user learns they've been moved
to Apple to avoid a charge. All existing state-derivation logic (key present,
`networkMonitor.isOnline`, `lastEngineUsed`, meter values) is reused as-is; only
its presentation changes.

## Components

- **New `MenuCardView.swift`** — the direction card: renders caption, shortcut,
  chevron, and direction text, and draws its own highlight. One responsibility:
  present a direction row inside a menu. Keeps `AppDelegate` from growing further.
- **Modify `AppDelegate.swift`** — build the new menu (two cards + status row +
  footer); replace `buildMenuHeader()`, `buildEngineStatusView()`,
  `buildUsageView()` with `buildStatusRow()`; merge `updateEngineStatus()` and
  `updateUsageDisplay()` into `updateStatusRow()`; drop `translateItem`/`readItem`
  and the language row items; `refreshLanguageMenus()` updates the card direction
  text instead of item titles.

**Unchanged:** hotkey registration and routing, `translateNow()`/`previewNow()`/
`readNow()` (still the hotkey actions), the language submenus and their checkmark
logic, `menuWillOpen` refresh (now calls `updateStatusRow()`), preview, metering,
and every translation path.

## Testing

App-layer AppKit UI (no app-side unit target): **live verification**.
- Both cards show the right direction; changing a language updates the card text
  immediately and checkmarks land on the right entry.
- Hover highlights each card (blue fill, white text) and opens its submenu.
- All six status states render correctly — force the capped state and confirm the
  message shows in full without truncation.
- Footer items work; ⌘, and ⌘Q still bound.
- Hotkeys (⌥⌘T / ⌥⌘R / preview) still trigger translations — the removed action
  rows must not have broken the actions themselves.

## Out of scope

- Any change to translation, preview, permission, or metering behavior.
- Restoring click-to-translate from the menu (deliberately dropped).
- Theming beyond the system accent / standard menu materials.

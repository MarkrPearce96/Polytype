# Compose Preview & Back-Translation — Design

**Date:** 2026-07-11
**Status:** Approved (design)

## Goal

Give the user confidence before sending a message they can't read. Today's
Compose (⌥⌘T) translates the focused field's English into the target language
and pastes it back **immediately and blind**. Preview mode inserts a
**confirm step**: it shows what will be sent *and what that means back in
English*, and only pastes if the user approves.

## Use case

Messaging family in Traditional Chinese (and 8 other languages) via LINE. The
user cannot read the target language, so the round-trip "here's what it says,
here's what it means back" removes the anxiety of sending something wrong.

## Settings model

A new **Preview** section in Settings with two controls:

- **Toggle 1 — "Preview before inserting"** (`previewEnabled`, default **off**).
  Off preserves today's behavior exactly (instant replace, no preview anywhere).
- **Toggle 2 — "Preview trigger"** (`previewUsesComposeHotkey`, default **false**;
  shown only when Toggle 1 is on). Two choices:
  - **Separate hotkey** (`false`): ⌥⌘T stays instant; a second, recordable
    **preview hotkey** (default = the Compose combo plus ⇧, i.e. ⌥⇧⌘T) runs the
    preview flow. Both are live at once.
  - **Use my Compose hotkey** (`true`): ⌥⌘T itself runs the preview flow instead
    of instant replace. No separate preview hotkey is registered; instant replace
    is unreachable until the user flips this back.
- When Toggle 1 is on **and** trigger is "Separate hotkey", a **HotkeyRecorder**
  for the preview hotkey appears (same control as Compose/Read).

### Trigger routing (the three reachable states)

| `previewEnabled` | `previewUsesComposeHotkey` | ⌥⌘T does | Preview hotkey |
|---|---|---|---|
| false | — | instant replace | not registered |
| true | false | instant replace | registered → preview |
| true | true | preview | not registered |

Changing any of these settings re-registers hotkeys immediately (no relaunch).

## Preview flow

1. **Capture** the English exactly as instant does: copy the current selection;
   if nothing is selected, select-all then copy (reusing the existing capture
   logic in `TranslateService`). Empty/whitespace → `∅`, no popup.
2. **Forward translate** English → `LanguagePrefs.composeTargetCode` via the
   normal engine (`QuotaGate` → Google, Apple fallback). This is the text that
   will be sent, so quality matters — identical cost to instant. On failure →
   `⚠`, no popup.
3. **Back-translate** the forward result (target → English) on the **Apple
   on-device engine directly** (zero Google quota, offline-capable). If Apple is
   unavailable (macOS < 15 or the language pack isn't downloaded) or throws, fall
   back to the normal quota-gated engine for the back-check (still auto-protected,
   so it can never cost money). If that also fails, show the popup **without** the
   "means back" line rather than erroring.
4. **Show the popup** (below) near the cursor, once both translations are ready.
5. **Confirm (Return)** → paste the forward result in place using the exact same
   paste-and-restore-clipboard mechanism as instant; status `✓`;
   `onEngineUsed` reflects the forward engine.
6. **Cancel (Esc / click away / auto-dismiss)** → nothing pasted, original text
   untouched, clipboard restored, return to idle.

The `busy` flag and 25-second watchdog guard the preview flow exactly as they
guard instant, so a stalled translation can't wedge the hotkey.

## Back-translation engine policy (money)

- The forward translation is the same single call instant already makes, metered
  the same way — **preview adds no forward-translation cost**.
- The back-check runs on Apple on-device → **zero Google characters**, so
  enabling preview never eats the 500k free tier or trips the auto-protect limit
  sooner.
- Apple-unavailable fallback uses the quota-gated engine, which is already
  incapable of causing a charge. **Never-charge guarantee is preserved.**

## Popup UI

A floating, **non-activating** panel near the cursor (same window class and
clamping as `ResultPopup`, but a richer three-part layout). It never becomes key
and never steals focus from the target field — essential so the confirming paste
lands in the right place.

```
┌────────────────────────────────────────────┐
│  YOU TYPED                                   │
│  Are you free for dinner Sunday?             │
│                                              │
│  WILL SEND · Traditional Chinese             │
│  星期天有空吃晚飯嗎？                          │   ← emphasized
│                                              │
│  MEANS BACK · Apple                          │
│  Do you have time for dinner on Sunday?      │
│  ────────────────────────────────────────    │
│  ⏎ Insert          esc Cancel                │
└────────────────────────────────────────────┘
```

- **YOU TYPED** — the captured English.
- **WILL SEND · <language name>** — the forward translation, visually emphasized
  (larger/bolder) as the important line. Language name from `Languages.name(for:)`.
- **MEANS BACK · <engine>** — the back-translation, labeled with which engine
  produced it ("Apple" or the fallback). Omitted if step 3 produced nothing.
- **Footer** — the ⏎ Insert / esc Cancel hints.

### Interaction & key interception

- **Return (36) / keypad Enter (76) → Insert.**
- **Esc (53) → Cancel.** A click anywhere → Cancel. Auto-dismiss (length-scaled,
  same idea as `ResultPopup`) → Cancel.
- **Critical safety:** while the popup is visible, the app installs a short-lived
  `CGEvent` tap (session level, requires the Accessibility grant the app already
  has) that **consumes** Return/Enter and Esc so they drive only the preview and
  **never reach the chat app underneath** — otherwise a Return meant for "Insert"
  could send a half-finished message in LINE. All other keys pass through. The tap
  is torn down the moment the popup dismisses.

## Components

- **New `ComposePreviewPopup.swift`** — the floating panel: builds the three-part
  layout, positions/clamps near the cursor, owns the confirm/cancel key handling
  and the `CGEvent` tap, and calls back `onInsert` / `onCancel`. One responsibility:
  present a translation for confirmation. Modeled on `ResultPopup`.
- **Modify `TranslateService.swift`** — add `translateSelectionWithPreview()` that
  reuses the capture path, does the forward translate, then the back-translate
  (Apple-first policy), shows `ComposePreviewPopup`, and on confirm performs the
  existing paste-and-restore. Add an optional `backTranslateEngine` (the Apple
  engine) injected at construction; nil on macOS < 15 → fallback path.
- **Modify hotkey layer (`HotkeyController.swift` / `HotkeyAccess`)** — support a
  third registerable hotkey (preview) and route the Compose hotkey to either
  instant or preview per settings. Register/unregister on settings change.
- **Modify `Language.swift` (prefs)** — add persisted `previewEnabled: Bool`,
  `previewUsesComposeHotkey: Bool`, and the preview hotkey's keyCode/mods/display
  (same persistence shape as Compose/Read).
- **Modify `AppDelegate.swift`** — build the Apple back-translate engine (when
  available) and pass it to `TranslateService`; wire the preview hotkey action and
  the Compose-hotkey routing; re-apply hotkey registration when Settings change.
- **Modify `SettingsWindow.swift`** — the new **Preview** section (two toggles +
  conditional preview HotkeyRecorder), matching the existing grouped-Form style.

## Error handling & edge cases

- Empty/whitespace capture → `∅`, no popup (as instant).
- Forward translate throws → `⚠`, no popup.
- Back-translate throws on both Apple and fallback → popup shown without the
  "means back" line; Insert/Cancel still work.
- Preview already showing when the hotkey fires again → ignored via `busy` (a new
  translation doesn't start until the current preview resolves).
- Settings toggled while a preview is open → the open preview finishes under the
  rules it started with; new registration applies to the next invocation.

## Metering guarantee

Enabling and using preview must never increase Google-billed characters beyond
the single forward translation instant already performs. Verified live: preview
a phrase and confirm the usage meter increases by only the forward text's length
(the Apple back-check adds nothing).

## Testing

Consistent with the app's UI layers (no app-side unit target): **build + live
verification**. Manual checks:
- All three trigger states behave per the routing table; toggling re-registers
  hotkeys without relaunch.
- Preview shows all three lines; Return inserts in place; Esc/click/timeout cancel
  with the field untouched.
- Return/Esc pressed over the preview do **not** leak into the chat app (no stray
  newline/send, no dialog dismissal).
- Back-translation uses Apple (label reads "Apple") when available; the usage
  meter rises only by the forward text length.
- Offline: preview still works end-to-end via the Apple fallback path.

TranslationCore's engine/quota logic is already unit-tested and is reused
unchanged; no new core logic requiring unit tests is introduced.

## Out of scope

- Editing the translation in the popup before inserting (view-only for now).
- Preview for Read mode (Read is already a non-destructive popup).
- Alternative-translation choices, pronunciation/romanization, history.

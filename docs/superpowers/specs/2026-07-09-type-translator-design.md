# Type Translator — Design Spec

**Date:** 2026-07-09
**Status:** Approved (design), pending implementation plan

## Summary

A native macOS **input method** that lets you type in English and produces
**Taiwanese Mandarin (Traditional, zh-TW)** inline in any app. You switch to it
from the input-source menu (like a Chinese keyboard), type an English sentence,
and it previews the Mandarin translation as underlined "composing" text; you
press Enter to commit, and again to send. It works system-wide (Messages, Slack,
browsers, etc.).

## Goals

- Type English, get natural Taiwanese Mandarin (Traditional characters) inline.
- Sentence-level translation (not word-by-word) for quality.
- Preview the translation before it's committed/sent — never send un-translated
  or unreviewed text by accident.
- **Free to run:** DeepL free tier as primary engine, Apple's on-device
  Translation framework as an always-available fallback (offline / quota-safe).
- Works in any macOS app as a real system input source.

## Non-Goals (v1 — YAGNI)

- No language picker UI — target is fixed to zh-TW (engine still takes a target
  parameter so this can be added later).
- No word-by-word / live-as-you-type translation.
- No paid/LLM engines (design allows adding one later behind the same interface).
- No notarized/distributable build — development/self-signed, personal use.

## User Experience

**Activation:** App installs to `~/Library/Input Methods/`. User adds
"Type Translator" under System Settings → Keyboard → Input Sources, and selects
it from the input-source menu when they want to translate. Switching back to the
normal ABC keyboard gives plain English.

**Typing flow (in any app, including messengers):**

| Step | Action | Result | Sent? |
|------|--------|--------|-------|
| 1 | Type `how are you?` | Sentence-ending punctuation triggers translation; underlined English is replaced by underlined 你好嗎 (preview) | No |
| 2 | Press **Enter** | Mandarin is committed as real text | No |
| 3 | Press **Enter** | Nothing underlined → Enter passes to the app | **Yes, sends** |

- **Esc** at any point discards the translation and restores the English buffer.
- **Key guarantee:** while any text is underlined (un-committed), the input
  method consumes Enter — the host app never sees it, so a message can never be
  sent prematurely. This is the same mechanism Chinese/Japanese input methods
  use.
- The exact translation trigger (punctuation vs. first Enter) is a small,
  isolated setting we can tune during the build.
- While a translation call is in flight (~0.3–1s), the buffer stays underlined
  so nothing leaks out early.

## Architecture

Four independently-understandable pieces:

### 1. Input Controller (`IMKInputController` subclass)
The core input-method logic. Receives each keystroke while active, manages the
underlined composing buffer, detects the translation trigger, requests
translation from the engine layer, renders the preview, and handles
commit/Esc/Enter semantics. Deliberately **thin** — it contains no knowledge of
*how* translation is performed.

### 2. Translation Engine layer
A small protocol:

```
protocol TranslationEngine {
    func translate(_ english: String, to target: String) async throws -> String
}
```

Implementations:
- **`DeepLEngine`** — calls DeepL's REST API. Target `ZH-HANT` for Traditional.
  Reads the API key from Keychain. Throws on network error / quota exceeded /
  missing key.
- **`AppleEngine`** — uses Apple's on-device Translation framework (macOS 26,
  available on this machine) with zh-TW. Works offline once the language pack is
  downloaded.
- **`FallbackChain`** (also conforms to `TranslationEngine`) — tries DeepL
  first; on any failure (no internet, quota exceeded, error, or no key
  configured) transparently falls back to `AppleEngine`. This is what the Input
  Controller talks to. Guarantees a translation is always available.

### 3. Settings
A small preferences window:
- Field to paste the **DeepL API key** → stored in the **macOS Keychain**.
- Button to **download the zh-TW language pack** for the Apple fallback
  (one-time; needed for offline use).
- With no DeepL key, the app runs Apple-only.

### 4. App shell
The bundle wiring macOS needs to load the input method: `IMKServer`,
`Info.plist` declaring the input-method component, connection name, and
icon/menu entry.

## Data Flow

```
keystroke → Input Controller → composing buffer (underlined)
   → [trigger: sentence-ending punctuation]
   → FallbackChain.translate(buffer, "zh-TW")
        → DeepLEngine (primary)  --fail-->  AppleEngine (fallback)
   → replace buffer with Mandarin (underlined preview)
   → Enter → commit as real text
   → Enter (nothing marked) → host app sends
```

## Error Handling

- **DeepL failure of any kind** (offline, quota, HTTP error, no key): silently
  fall back to Apple on-device. No user-facing error in the typing path.
- **Apple engine failure** (e.g. language pack not yet downloaded): leave the
  English buffer intact and surface a subtle, non-blocking indication;
  the user can still commit their English or open Settings to download the pack.
- **Translation latency:** buffer remains underlined and locked until the async
  call returns; Enter is still eaten during this window.

## Testing Strategy

- **Engine layer (unit-tested, where correctness lives):**
  - `DeepLEngine` with mocked HTTP — success, quota-exceeded, network error,
    correct target/params.
  - `AppleEngine` — basic translate; graceful behavior when pack missing.
  - `FallbackChain` — verify fallback triggers on each DeepL failure mode, and
    that DeepL is preferred when healthy.
- **Input Controller:** kept thin; exercised **manually** in a scratch text
  field and real apps (Messages, Notes, Slack), since IMK behavior is hard to
  unit-test. Real complexity is pushed into the tested engine layer.

## Tech Stack

- Swift + **InputMethodKit**, built in Xcode.
- Swift Concurrency (async/await) for translation calls.
- `URLSession` for the DeepL REST API.
- Apple **Translation** framework for on-device fallback.
- **Keychain** for the DeepL API key.
- Installs to `~/Library/Input Methods/`; development/self-signed signature.

## Future Extensions (not in v1)

- Language picker (engine already parameterized by target).
- Additional engines behind `TranslationEngine` (e.g. an LLM for extra polish).
- Configurable translation-trigger and hotkeys.

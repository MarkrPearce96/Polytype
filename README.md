# Type Translator

A macOS menu-bar app that translates **English → Taiwanese Mandarin (Traditional
Chinese, zh-TW)** in place. Type a message in any app, press a hotkey, and the
text is replaced with the translation — ready to send.

## How it works

Press the hotkey (default **⌥⌘T**) and the app:

1. Copies your current selection — or, if nothing is selected, selects-all and
   copies the field (ideal for a message you just typed).
2. Translates it: **Google Cloud Translation** first, falling back to Apple's
   **on-device** translation if Google is unreachable or has no key.
3. Pastes the Traditional Chinese back in place, then restores your clipboard.

The menu shows which engine produced the last translation ("Last translation:
Google" / "Apple (offline)").

## Setup

### 1. Build and install

```sh
./scripts/install-bar.sh
```

This builds the app and installs it to `/Applications`, then launches it. You'll
see a **譯** icon in the menu bar.

### 2. Grant Accessibility permission

The hotkey needs to read and replace text via synthesized keystrokes:

**System Settings → Privacy & Security → Accessibility →** enable **Type
Translator**.

### 3. Add a Google Cloud Translation API key (free tier: 500,000 chars/month)

1. In the [Google Cloud Console](https://console.cloud.google.com/): create a
   project, enable the **Cloud Translation API** (this prompts you to add a
   billing card — you are not charged under 500k characters/month).
2. **APIs & Services → Credentials → Create Credentials → API key.** Restrict the
   key to the **Cloud Translation API**.
3. Paste it into **譯 → Settings… → Google API key → Save key**.

Alternatively, leave the key blank to use only Apple's on-device engine — fully
free and offline, but lower quality. Use **Settings → Download zh-TW pack** once
to fetch the language model.

### 4. (Optional) Launch at login

**譯 → Settings… → Launch at login.** (Requires the app to be in `/Applications`,
which `install-bar.sh` handles.)

## Usage

- **Compose a message** (empty-ish field): type it, press the hotkey — the whole
  field is translated.
- **Existing document** (a note with other text): **select** the part you want
  first, then press the hotkey — only the selection is touched.
- **Change the hotkey:** Settings → Shortcut → click and press a new combo
  (must include ⌘, ⌥, ⌃, or ⇧).

## Project layout

- `TranslationCore/` — Swift package with the translation engines and support
  types, fully unit-tested (`swift test --package-path TranslationCore`):
  - `TranslationEngine` protocol + `TranslationError`
  - `GoogleEngine`, `AppleEngine` (on-device), and the older `DeepLEngine`
  - `FallbackChain` — primary engine with automatic fallback
  - `SecretStore` / `KeychainSecretStore`, `HTTPClient`, timeout helpers
- `TypeTranslatorApp/` — the `TypeTranslatorBar` menu-bar executable:
  global hotkey, clipboard-swap translate-in-place, settings, login item.
- `scripts/build-bar.sh` — build + assemble + sign the `.app`.
- `scripts/install-bar.sh` — build and install to `/Applications`.

## Notes

- Signing uses your local Apple Development identity so the Accessibility grant
  persists across rebuilds; no paid Apple Developer account is required to run
  the app yourself.
- An earlier approach implemented this as a system **input method**
  (InputMethodKit). On current macOS the input-source scanner only registers
  input methods signed with a Developer ID and notarized (a paid account), so the
  project pivoted to this menu-bar + hotkey design, which needs neither. The
  input-method code remains in git history.

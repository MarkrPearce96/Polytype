# Polytype

A macOS menu-bar app that translates text in place. Type a message in any app,
press a hotkey, and the text is replaced with the translation — ready to send.
Supports multiple languages with configurable source and target languages.

## How it works

Press the hotkey (default **⌥⌘T** for Compose, **⌥⌘R** for Read) and the app:

1. Copies your current selection — or, if nothing is selected, selects-all and
   copies the field (ideal for a message you just typed).
2. Translates it using the selected language pair: **Google Cloud Translation**
   first, falling back to Apple's **on-device** translation if Google is
   unreachable or has no key.
3. For Compose: pastes the translated text back in place, then restores your
   clipboard. For Read: shows a popup with the translation (read-only).

The menu shows which engine produced the last translation ("Last translation:
Google" / "Apple (offline)").

## Setup

On first launch, a **Setup Assistant** walks you through the steps below —
Accessibility permission, your Google API key, your language, and your two
shortcuts — and only appears once. You can reopen it anytime from **譯 → Setup
Assistant…**. The manual steps below cover the same ground.

### 1. Build and install

```sh
./scripts/install-bar.sh
```

This builds the app and installs it to `/Applications`, then launches it. You'll
see a **譯** icon in the menu bar.

### 2. Grant Accessibility permission

The hotkey needs to read and replace text via synthesized keystrokes:

**System Settings → Privacy & Security → Accessibility →** enable **Polytype**.

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

- **Compose a message** (⌥⌘T, default): type it, press the hotkey — the whole
  field is translated to your selected target language (default Traditional
  Chinese) and pasted back. Change the target language from the **Compose** card
  in the 譯 menu.
- **Existing document** (select first): **select** the text you want translated,
  then press the hotkey — only the selection is replaced.
- **Preview before sending (optional):** turn on **Settings → Preview → "Preview
  before inserting"** to see the translation *and what it means back in English*
  before it's inserted — press **Return** to insert, **Esc** to cancel. Choose
  whether it runs on a separate shortcut (default ⌥⇧⌘T) or takes over your Compose
  shortcut. The back-check prefers Apple's free on-device engine (macOS 15 with the
  language downloaded), so it usually doesn't count against your Google free tier;
  when Apple isn't available it falls back to Google. Either way it never *charges*
  — the free-tier auto-protect still applies.
- **Read a message** (⌥⌘R, default): select any text on your screen (in a
  message, web page, PDF, etc.), press the hotkey — a small popup near your cursor
  shows the English translation. Nothing is changed or pasted; it's read-only. Change
  the source language from the **Read** card in the 譯 menu (default Auto-detect,
  which requires internet; pick a specific language to work fully offline). If nothing is selected,
  the app beeps.
- **Available languages:** Traditional Chinese, Simplified Chinese, Japanese,
  Korean, Spanish, French, German, Thai, Vietnamese.
- **Customize the hotkeys:** Both shortcuts are customizable in Settings → Shortcut
  — click and press a new combo (must include ⌘, ⌥, ⌃, or ⇧).
- **Monthly usage tracking** (Google free tier): The menu and Settings show your
  monthly character count. The app automatically switches to Apple's on-device
  engine before reaching the 500k limit to prevent charges — you'll receive a
  one-time notification when it does. The counter resets each calendar month.
- **Usage calibration**: In Settings, enter your exact current character count
  (from the Google Cloud Console) and renewal date — the counter will then reset
  on that date, rolling forward monthly.

## Project layout

- `TranslationCore/` — Swift package with the translation engines and support
  types, fully unit-tested (`swift test --package-path TranslationCore`):
  - `TranslationEngine` protocol + `TranslationError`
  - `GoogleEngine` and `AppleEngine` (on-device)
  - `FallbackChain` — primary engine with automatic fallback
  - `SecretStore` / `KeychainSecretStore`, `HTTPClient`, timeout helpers
- `PolytypeApp/` — the `PolytypeBar` menu-bar executable:
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

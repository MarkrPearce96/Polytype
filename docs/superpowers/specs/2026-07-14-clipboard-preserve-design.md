# Preserve All Clipboard Types Across a Translation — Design

**Date:** 2026-07-14
**Status:** Approved (design)

## Problem

To translate, `TranslateService` borrows the system clipboard: it synthesizes
⌘C to copy the field, reads the text, puts the translation on the clipboard,
synthesizes ⌘V, then restores the user's original clipboard. But it only saves
and restores the **text** type (`pb.string(forType: .string)`). If the user had
a non-text item copied — an **image, a file, styled (RTF) text** — running a
translation silently discards it: after the operation, that content is gone from
the clipboard. This is a surprising, invisible data-loss side effect.

## Fix

Snapshot and restore the **whole pasteboard**, not just its text.

Two private helpers in `TranslateService`:

- `snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem]` — for each item
  in `pb.pasteboardItems`, create a fresh `NSPasteboardItem` and copy the data of
  every type (`item.types` → `item.data(forType:)`) into it. Returns the fresh
  copies (the originals can't be re-added to a pasteboard).
- `restorePasteboard(_ items: [NSPasteboardItem], to pb: NSPasteboard)` —
  `pb.clearContents()` then `pb.writeObjects(items)` (empty array → clipboard is
  simply cleared, matching prior behavior when there was nothing to restore).

Thread `[NSPasteboardItem]` in place of `String?` through the methods that carry
the saved clipboard: the two capture points in `translateSelectionInPlace` and
`translateSelectionWithPreview`, the Read capture in `translateSelectionToPopup`,
and the parameters of `previewClipboard`, `translateClipboard`, `finish`, and
`finishRead`. The `restore` in `finish`/`finishRead` calls `restorePasteboard`.

**Unchanged:** the places that read the *copied English* out of the clipboard
(`pb.string(forType: .string)`) stay as-is — only the save/restore path changes.
The synthetic-key capture flow, timing, watchdog, and metering are untouched.

## Limitation

"Promised"/lazy pasteboard data (e.g. an unmaterialized file-drag promise) returns
`nil` from `item.data(forType:)` and is skipped — those bytes don't exist to copy.
The common concrete cases users actually lose today (image, file, RTF, plain and
multi-representation text) are fully preserved. This moves the app from "only text
survives a translation" to "all concrete clipboard content survives."

## Testing

App-layer AppKit/clipboard code (no app-side unit target): **live verification**.
- Copy an image (or a file in Finder), run a Compose translation → the image/file
  is still on the clipboard afterward and pastes normally.
- Copy plain text, translate → the original text is restored (regression check).
- Read mode (⌥⌘R) likewise leaves a non-text clipboard intact.

## Out of scope

- Preserving promised/lazy pasteboard data (inherently impossible to snapshot).
- Any change to the translation, timing, permission, or metering logic.

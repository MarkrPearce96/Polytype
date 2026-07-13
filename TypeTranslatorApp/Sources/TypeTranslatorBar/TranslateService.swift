import AppKit
import Carbon
import TranslationCore

/// The core action: translate whatever text is in the frontmost app's focused
/// field, in place, without the user having to select anything manually.
///
/// Flow on hotkey press:
///   1. Remember the current clipboard so we can put it back.
///   2. Synthesize ⌘A then ⌘C to select-all and copy the field.
///   3. Poll the clipboard until the copy lands, read the English.
///   4. Translate via the shared engine (DeepL → Apple fallback).
///   5. Put the Mandarin on the clipboard and synthesize ⌘V to paste it.
///   6. Restore the original clipboard a beat later.
///
/// Steps 2/5 require Accessibility permission (to post synthetic keystrokes).
/// Thread-safe flag set by `FallbackChain.onFallback` (which may fire off the
/// main actor) so the service can tell, after a translation, whether the Apple
/// fallback was used instead of Google.
final class FallbackFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

@MainActor
final class TranslateService {
    private let engine: TranslationEngine
    private let backTranslateEngine: TranslationEngine?
    private let fallbackFlag: FallbackFlag
    private var busy = false
    private var opToken = 0

    /// Brief single-glyph status for the menu-bar button ("…", "✓", "⚠", "∅").
    var onStatus: ((String) -> Void)?
    /// Name of the engine that produced the last successful translation
    /// ("Google" or "Apple (offline)").
    var onEngineUsed: ((String) -> Void)?

    init(engine: TranslationEngine, fallbackFlag: FallbackFlag = FallbackFlag(),
         backTranslateEngine: TranslationEngine? = nil) {
        self.engine = engine
        self.fallbackFlag = fallbackFlag
        self.backTranslateEngine = backTranslateEngine
    }

    func translateSelectionInPlace() {
        guard !busy else { return }
        guard ensureAccessibility() else {
            onStatus?("⚠")
            promptAccessibility()
            return
        }
        busy = true
        onStatus?("…")
        armWatchdog()

        let pb = NSPasteboard.general
        let saved = snapshotPasteboard(pb)

        // Copy whatever is CURRENTLY selected first — don't select-all yet. If the
        // user selected a sentence, this grabs just that. Only if nothing is
        // selected (clipboard unchanged) do we fall back to select-all, which
        // suits an otherwise-empty compose field but would grab a whole document.
        let before = pb.changeCount
        postCommandKey(CGKeyCode(kVK_ANSI_C))
        waitForClipboardChange(pb, from: before, attempts: 12) { [weak self] hadSelection in
            guard let self else { return }
            if hadSelection {
                self.translateClipboard(pb: pb, saved: saved)
            } else {
                // Nothing was selected → select all, then copy.
                let before2 = pb.changeCount
                self.postCommandKey(CGKeyCode(kVK_ANSI_A))
                self.postCommandKey(CGKeyCode(kVK_ANSI_C))
                self.waitForClipboardChange(pb, from: before2, attempts: 25) { changed in
                    if changed {
                        self.translateClipboard(pb: pb, saved: saved)
                    } else {
                        self.finish(status: "∅", restore: saved, to: pb, after: 0.1)
                    }
                }
            }
        }
    }

    /// Like `translateSelectionInPlace`, but instead of pasting immediately it
    /// shows a confirm-before-insert preview with a back-translation.
    func translateSelectionWithPreview() {
        guard !busy else { return }
        guard ensureAccessibility() else {
            onStatus?("⚠")
            promptAccessibility()
            return
        }
        busy = true
        onStatus?("…")
        armWatchdog()

        let pb = NSPasteboard.general
        let saved = snapshotPasteboard(pb)
        let cursor = NSEvent.mouseLocation
        let before = pb.changeCount
        postCommandKey(CGKeyCode(kVK_ANSI_C))
        waitForClipboardChange(pb, from: before, attempts: 12) { [weak self] hadSelection in
            guard let self else { return }
            if hadSelection {
                self.previewClipboard(pb: pb, saved: saved, at: cursor)
            } else {
                let before2 = pb.changeCount
                self.postCommandKey(CGKeyCode(kVK_ANSI_A))
                self.postCommandKey(CGKeyCode(kVK_ANSI_C))
                self.waitForClipboardChange(pb, from: before2, attempts: 25) { changed in
                    if changed {
                        self.previewClipboard(pb: pb, saved: saved, at: cursor)
                    } else {
                        self.finish(status: "∅", restore: saved, to: pb, after: 0.1)
                    }
                }
            }
        }
    }

    /// Forward-translate the clipboard English, back-translate for reassurance,
    /// then show the preview. Paste only happens on confirm.
    private func previewClipboard(pb: NSPasteboard, saved: [NSPasteboardItem], at cursor: NSPoint) {
        let english = pb.string(forType: .string) ?? ""
        guard !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish(status: "∅", restore: saved, to: pb, after: 0.1)
            return
        }
        let target = LanguagePrefs.composeTargetCode
        Task { @MainActor in
            do {
                self.fallbackFlag.value = false
                let translated = try await self.engine.translate(english, from: "en", to: target)
                guard !translated.isEmpty else {
                    self.finish(status: "∅", restore: saved, to: pb, after: 0.1)
                    return
                }
                let forwardEngine = self.fallbackFlag.value ? "apple" : "google"
                let fullName = Languages.name(for: target)
                let shortName = String(fullName.split(separator: " (").first ?? Substring(fullName))
                // Forward translation is done; show the preview immediately and let
                // the back-check fill in, so it feels as fast as an instant paste.
                // Also disarm the watchdog — we're now waiting on the user, which
                // can outlast the 25s backstop (the popup's own timer takes over).
                self.disarmWatchdog()
                ComposePreviewPopup.shared.show(
                    original: english, translation: translated, languageName: shortName, at: cursor,
                    onInsert: { [weak self] in
                        guard let self else { return }
                        pb.clearContents()
                        pb.setString(translated, forType: .string)
                        self.postCommandKey(CGKeyCode(kVK_ANSI_V))
                        self.onEngineUsed?(forwardEngine)
                        self.finish(status: "✓", restore: saved, to: pb, after: 0.4)
                    },
                    onCancel: { [weak self] in
                        self?.finish(status: "", restore: saved, to: pb, after: 0.1)
                    },
                    back: { [weak self] in
                        guard let self else { return (nil, nil) }
                        return await self.backTranslate(translated, from: target)
                    })
            } catch {
                self.onEngineUsed?("failed")
                self.finish(status: "⚠", restore: saved, to: pb, after: 0.1)
            }
        }
    }

    /// Back-translation for the preview's reassurance line. Apple on-device first
    /// (zero Google quota); else the quota-gated engine (still never charges);
    /// else nil (popup omits the "means back" line). Returns (text, engineLabel).
    private func backTranslate(_ text: String, from source: String) async -> (String?, String?) {
        if let apple = backTranslateEngine,
           let r = try? await apple.translate(text, from: source, to: "en"), !r.isEmpty {
            return (r, "Apple")
        }
        if let r = try? await engine.translate(text, from: source, to: "en"), !r.isEmpty {
            return (r, "Google")
        }
        return (nil, nil)
    }

    /// Translate whatever text is now on the clipboard, then paste it back.
    private func translateClipboard(pb: NSPasteboard, saved: [NSPasteboardItem]) {
        let english = pb.string(forType: .string) ?? ""
        guard !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish(status: "∅", restore: saved, to: pb, after: 0.1)
            return
        }
        Task { @MainActor in
            do {
                self.fallbackFlag.value = false   // reset before the call
                let mandarin = try await self.engine.translate(english, from: "en", to: LanguagePrefs.composeTargetCode)
                guard !mandarin.isEmpty else {
                    self.finish(status: "∅", restore: saved, to: pb, after: 0.1)
                    return
                }
                pb.clearContents()
                pb.setString(mandarin, forType: .string)
                self.postCommandKey(CGKeyCode(kVK_ANSI_V))   // paste Mandarin
                self.onEngineUsed?(self.fallbackFlag.value ? "apple" : "google")
                self.finish(status: "✓", restore: saved, to: pb, after: 0.4)
            } catch {
                self.onEngineUsed?("failed")
                self.finish(status: "⚠", restore: saved, to: pb, after: 0.1)
            }
        }
    }

    /// Read mode: translate the current selection (from the selected Read language, or auto-detected) to English and show it in a popup near the cursor. Never pastes; restores the clipboard.
    func translateSelectionToPopup() {
        guard !busy else { return }
        guard ensureAccessibility() else { onStatus?("⚠"); promptAccessibility(); return }
        busy = true
        onStatus?("…")
        armWatchdog()

        let pb = NSPasteboard.general
        let saved = snapshotPasteboard(pb)
        let cursor = NSEvent.mouseLocation
        let before = pb.changeCount
        postCommandKey(CGKeyCode(kVK_ANSI_C))   // copy selection only (no select-all)

        waitForClipboardChange(pb, from: before, attempts: 12) { [weak self] hadSelection in
            guard let self else { return }
            guard hadSelection else {
                NSSound.beep()
                self.finishRead(status: "∅", restore: saved, to: pb)
                return
            }
            let chinese = pb.string(forType: .string) ?? ""
            guard !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep()
                self.finishRead(status: "∅", restore: saved, to: pb)
                return
            }
            Task { @MainActor in
                do {
                    self.fallbackFlag.value = false   // reset before the call
                    let english = try await self.engine.translate(chinese, from: LanguagePrefs.effectiveReadSourceCode, to: "en")
                    ResultPopup.shared.show(english.isEmpty ? "(no translation)" : english, at: cursor)
                    self.onEngineUsed?(self.fallbackFlag.value ? "apple" : "google")
                    self.finishRead(status: "✓", restore: saved, to: pb)
                } catch {
                    let hint = LanguagePrefs.effectiveReadSourceCode == Languages.autoCode
                        ? "Couldn't translate. If you're offline, pick a Read language in the menu."
                        : "Couldn't translate — check your connection, or download this language in Settings for offline use."
                    ResultPopup.shared.show(hint, at: cursor)
                    self.onEngineUsed?("failed")
                    self.finishRead(status: "⚠", restore: saved, to: pb)
                }
            }
        }
    }

    /// Read mode never pastes, so restore the clipboard immediately.
    private func finishRead(status: String, restore saved: [NSPasteboardItem], to pb: NSPasteboard) {
        onStatus?(status)
        restorePasteboard(saved, to: pb)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.busy = false
            self?.onStatus?("")
        }
    }

    /// Backstop: if a translation never completes (e.g. a framework stall beyond
    /// its own timeouts), force the app back to idle so the hotkey keeps working.
    private func armWatchdog() {
        opToken += 1
        let token = opToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.busy, self.opToken == token else { return }
            self.onStatus?("⚠")
            self.busy = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.onStatus?("")
            }
        }
    }

    /// Cancel a pending watchdog by advancing the token so its armed check no-ops.
    /// Used once the preview popup is on screen (translation complete; the wait is
    /// now bounded by the popup's own dismiss timer instead).
    private func disarmWatchdog() {
        opToken += 1
    }

    // MARK: - Accessibility

    /// Returns true if we're trusted for Accessibility; prompts the system dialog
    /// on the first call when we're not.
    private func ensureAccessibility() -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private func promptAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = """
            Type Translator needs Accessibility access to read and replace the \
            selected text. Open System Settings ▸ Privacy & Security ▸ \
            Accessibility and enable “TypeTranslatorBar”, then try again.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Synthetic keys & clipboard

    private func postCommandKey(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func waitForClipboardChange(_ pb: NSPasteboard, from: Int, attempts: Int,
                                        done: @escaping (Bool) -> Void) {
        if pb.changeCount != from { done(true); return }
        if attempts <= 0 { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.waitForClipboardChange(pb, from: from, attempts: attempts - 1, done: done)
        }
    }

    /// Snapshot the ENTIRE clipboard (all items, all concrete types) so a
    /// translation can restore whatever the user had copied — an image, a file,
    /// styled text — not just plain text. Items are deep-copied into fresh
    /// NSPasteboardItems because the originals can't be re-added to a pasteboard.
    /// Promised/lazy data returns nil and is skipped (its bytes don't exist yet).
    private func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        var copies: [NSPasteboardItem] = []
        for item in pb.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            var wroteAnything = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    wroteAnything = true
                }
            }
            if wroteAnything { copies.append(copy) }
        }
        return copies
    }

    /// Restore a snapshot taken by `snapshotPasteboard`. An empty snapshot simply
    /// leaves the clipboard cleared (matching the prior "nothing to restore" case).
    private func restorePasteboard(_ items: [NSPasteboardItem], to pb: NSPasteboard) {
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }

    private func finish(status: String, restore saved: [NSPasteboardItem], to pb: NSPasteboard, after: TimeInterval) {
        onStatus?(status)
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            // Restore inline (no self capture) so a late timer always restores,
            // even if the service were being torn down.
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        // Clear the transient glyph shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.busy = false
            self?.onStatus?("")
        }
    }
}

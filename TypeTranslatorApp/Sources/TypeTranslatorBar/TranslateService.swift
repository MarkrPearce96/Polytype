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
    private let fallbackFlag: FallbackFlag
    private var busy = false
    private var opToken = 0

    /// Brief single-glyph status for the menu-bar button ("…", "✓", "⚠", "∅").
    var onStatus: ((String) -> Void)?
    /// Name of the engine that produced the last successful translation
    /// ("Google" or "Apple (offline)").
    var onEngineUsed: ((String) -> Void)?

    init(engine: TranslationEngine, fallbackFlag: FallbackFlag = FallbackFlag()) {
        self.engine = engine
        self.fallbackFlag = fallbackFlag
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
        let saved = pb.string(forType: .string)

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

    /// Translate whatever text is now on the clipboard, then paste it back.
    private func translateClipboard(pb: NSPasteboard, saved: String?) {
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
                self.onEngineUsed?(self.fallbackFlag.value ? "Apple (offline)" : "Google")
                self.finish(status: "✓", restore: saved, to: pb, after: 0.4)
            } catch {
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
        let saved = pb.string(forType: .string)
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
                    let english = try await self.engine.translate(chinese, from: LanguagePrefs.readSourceCode, to: "en")
                    ResultPopup.shared.show(english.isEmpty ? "(no translation)" : english, at: cursor)
                    self.finishRead(status: "✓", restore: saved, to: pb)
                } catch {
                    let hint = LanguagePrefs.readSourceCode == Languages.autoCode
                        ? "Couldn't translate. If you're offline, pick a Read language in the menu."
                        : "Couldn't translate — check your connection or API key."
                    ResultPopup.shared.show(hint, at: cursor)
                    self.finishRead(status: "⚠", restore: saved, to: pb)
                }
            }
        }
    }

    /// Read mode never pastes, so restore the clipboard immediately.
    private func finishRead(status: String, restore saved: String?, to pb: NSPasteboard) {
        onStatus?(status)
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
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

    private func finish(status: String, restore saved: String?, to pb: NSPasteboard, after: TimeInterval) {
        onStatus?(status)
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
        // Clear the transient glyph shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.busy = false
            self?.onStatus?("")
        }
    }
}

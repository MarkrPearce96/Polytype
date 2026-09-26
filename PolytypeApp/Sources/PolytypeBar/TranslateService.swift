import AppKit
import Carbon
import TranslationCore

/// The core action: translate whatever text is in the frontmost app's focused
/// field, in place, without the user having to select anything manually.
///
/// Flow on hotkey press:
///   1. Remember the current clipboard so we can put it back.
///   2. Synthesize ⌘C. If that copied something, that's the selection.
///   3. If nothing was selected, try to select just the paragraph at the
///      cursor via Accessibility (`SmartSelection`); if that isn't supported
///      by the focused app, fall back to ⌘A — but only translate the result
///      if it's short (see `selectAllWithGuard`), since a long document
///      select-all is almost never what was meant by "nothing selected."
///   4. Translate via the shared engine (Google → Apple fallback).
///   5. Put the translation on the clipboard and synthesize ⌘V to paste it.
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
        let saved = snapshotPasteboard(pb)

        // Copy whatever is CURRENTLY selected first — don't select-all yet. If the
        // user selected a sentence, this grabs just that. Only if nothing is
        // selected (clipboard unchanged) do we try a smarter fallback below.
        let before = pb.changeCount
        postCommandKey(CGKeyCode(kVK_ANSI_C))
        waitForClipboardChange(pb, from: before, attempts: 12) { [weak self] hadSelection in
            guard let self else { return }
            if hadSelection {
                self.translateClipboard(pb: pb, saved: saved)
            } else {
                self.trySmartParagraphSelection(pb: pb, saved: saved)
            }
        }
    }

    /// After a synthesized ⌘C copied nothing (no manual selection), tries to
    /// auto-select just the paragraph at the cursor. Retried once after a
    /// short delay if the first attempt fails — traced back to the very
    /// first real use right after a fresh install, which can hit a brief
    /// window where Accessibility calls transiently fail before the
    /// permission/process state has fully settled system-wide; a single
    /// short-delayed retry covers that without meaningfully slowing down
    /// the overwhelmingly common case where the first attempt already
    /// succeeds.
    private func trySmartParagraphSelection(pb: NSPasteboard, saved: [NSPasteboardItem], isRetry: Bool = false) {
        if SmartSelection.selectParagraphAtCursor() {
            // The target app just highlighted the paragraph at the cursor
            // for us — copy exactly that.
            let before = pb.changeCount
            postCommandKey(CGKeyCode(kVK_ANSI_C))
            waitForClipboardChange(pb, from: before, attempts: 12) { [weak self] changed in
                guard let self else { return }
                if changed {
                    self.translateClipboard(pb: pb, saved: saved)
                } else {
                    self.finish(status: "∅", restore: saved, to: pb, after: 0.1)
                }
            }
        } else if !isRetry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.trySmartParagraphSelection(pb: pb, saved: saved, isRetry: true)
            }
        } else {
            // The focused app doesn't support Accessibility text ranges (or
            // both tries failed for some other reason) — fall back to
            // select-all, but only translate it if it's short.
            selectAllWithGuard(pb: pb, saved: saved)
        }
    }

    /// Fallback when paragraph detection isn't available: select-all, then
    /// only translate the result if it's message-sized. A long document
    /// select-all is almost never what "nothing was selected" actually meant,
    /// so this beeps and asks for a manual selection instead of silently
    /// translating (and overwriting) the whole thing.
    private static let selectAllGuardLimit = 500

    private func selectAllWithGuard(pb: NSPasteboard, saved: [NSPasteboardItem]) {
        let before = pb.changeCount
        postCommandKey(CGKeyCode(kVK_ANSI_A))
        postCommandKey(CGKeyCode(kVK_ANSI_C))
        waitForClipboardChange(pb, from: before, attempts: 25) { [weak self] changed in
            guard let self else { return }
            guard changed else {
                self.finish(status: "∅", restore: saved, to: pb, after: 0.1)
                return
            }
            let text = pb.string(forType: .string) ?? ""
            if text.count > Self.selectAllGuardLimit {
                NSSound.beep()
                self.finish(status: "⚠", restore: saved, to: pb, after: 0.1)
            } else {
                self.translateClipboard(pb: pb, saved: saved)
            }
        }
    }

    /// Translate whatever text is now on the clipboard, then paste it back.
    private func translateClipboard(pb: NSPasteboard, saved: [NSPasteboardItem]) {
        let text = pb.string(forType: .string) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish(status: "∅", restore: saved, to: pb, after: 0.1)
            return
        }
        Task { @MainActor in
            do {
                self.fallbackFlag.value = false   // reset before the call
                let translated = try await self.engine.translate(
                    text, from: LanguagePrefs.effectiveComposeSourceCode, to: LanguagePrefs.composeTargetCode)
                guard !translated.isEmpty else {
                    self.finish(status: "∅", restore: saved, to: pb, after: 0.1)
                    return
                }
                pb.clearContents()
                pb.setString(translated, forType: .string)
                self.postCommandKey(CGKeyCode(kVK_ANSI_V))   // paste the translation
                self.onEngineUsed?(self.fallbackFlag.value ? "apple" : "google")
                self.finish(status: "✓", restore: saved, to: pb, after: 0.4)
            } catch {
                self.onEngineUsed?("failed")
                self.finish(status: "⚠", restore: saved, to: pb, after: 0.1)
            }
        }
    }

    /// Read mode: translate the current selection (from the selected Read source, or
    /// auto-detected) to the selected Read target and show it in a popup near the
    /// cursor. Never pastes; restores the clipboard.
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
            let selection = pb.string(forType: .string) ?? ""
            guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep()
                self.finishRead(status: "∅", restore: saved, to: pb)
                return
            }
            Task { @MainActor in
                do {
                    self.fallbackFlag.value = false   // reset before the call
                    let translated = try await self.engine.translate(
                        selection, from: LanguagePrefs.effectiveReadSourceCode, to: LanguagePrefs.readTargetCode)
                    ResultPopup.shared.show(translated.isEmpty ? "(no translation)" : translated, at: cursor)
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
            Polytype needs Accessibility access to read and replace the \
            selected text. Open System Settings ▸ Privacy & Security ▸ \
            Accessibility and enable “PolytypeBar”, then try again.
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

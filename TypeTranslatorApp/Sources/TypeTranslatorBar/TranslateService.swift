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
@MainActor
final class TranslateService {
    private let engine: TranslationEngine
    private let target = "zh-TW"
    private var busy = false

    /// Brief single-glyph status for the menu-bar button ("…", "✓", "⚠", "∅").
    var onStatus: ((String) -> Void)?

    init(engine: TranslationEngine) {
        self.engine = engine
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

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let before = pb.changeCount

        postCommandKey(CGKeyCode(kVK_ANSI_A))   // select all
        postCommandKey(CGKeyCode(kVK_ANSI_C))   // copy

        waitForClipboardChange(pb, from: before, attempts: 30) { [weak self] changed in
            guard let self else { return }
            let english = pb.string(forType: .string) ?? ""
            guard changed, !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.finish(status: "∅", restore: saved, to: pb, after: 0.1)
                return
            }
            Task { @MainActor in
                do {
                    let mandarin = try await self.engine.translate(english, to: self.target)
                    guard !mandarin.isEmpty else {
                        self.finish(status: "∅", restore: saved, to: pb, after: 0.1)
                        return
                    }
                    pb.clearContents()
                    pb.setString(mandarin, forType: .string)
                    self.postCommandKey(CGKeyCode(kVK_ANSI_V))   // paste Mandarin
                    self.finish(status: "✓", restore: saved, to: pb, after: 0.4)
                } catch {
                    self.finish(status: "⚠", restore: saved, to: pb, after: 0.1)
                }
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

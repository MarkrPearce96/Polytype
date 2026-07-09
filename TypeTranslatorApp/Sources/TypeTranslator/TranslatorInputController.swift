import InputMethodKit
import TranslationCore

/// The input controller macOS instantiates for each text field we're active in.
/// The `@objc(TranslatorInputController)` name is what the bundle's Info.plist
/// `InputMethodServerControllerClass` refers to.
///
/// Composing model (all while our input source is active):
///   1. Typed characters accumulate in `englishBuffer`, shown underlined.
///   2. Translation is requested when the user types sentence-ending punctuation
///      (`.?!`) preceded by a letter, or presses Enter on an untranslated buffer.
///   3. The underlined English is replaced by the underlined Mandarin preview.
///   4. Enter commits the Mandarin as real text (event consumed — never sends).
///   5. Enter with nothing underlined passes through to the app (sends/newline).
///   6. Esc discards the translation (restoring English), or clears the buffer.
@objc(TranslatorInputController)
class TranslatorInputController: IMKInputController {

    // MARK: State
    private var englishBuffer = ""
    private var previewMandarin: String?
    private var pending = false        // a translation call is in flight
    private var attempted = false      // a translation for the current buffer finished

    private let engine: TranslationEngine
    private let target = "zh-TW"

    // Key codes (US layout, layout-independent physical keys).
    private let kReturn: UInt16 = 36
    private let kKeypadEnter: UInt16 = 76
    private let kEscape: UInt16 = 53
    private let kDelete: UInt16 = 51

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        let secrets = KeychainSecretStore()
        let deepl = DeepLEngine(secrets: secrets, http: URLSessionHTTPClient())
        // DeepL is primary; Apple on-device is the offline/quota fallback.
        // AppleEngine is macOS 15+, so gate its construction (app floor is 14).
        if #available(macOS 15, *) {
            self.engine = FallbackChain(primary: deepl, fallback: AppleEngine())
        } else {
            self.engine = deepl
        }
        super.init(server: server, delegate: delegate, client: inputClient)
    }

    // MARK: Client / marked-text helpers

    private func currentClient() -> IMKTextInput? {
        client()
    }

    private func showMarked(_ text: String) {
        guard let c = currentClient() else { return }
        let attr = NSAttributedString(
            string: text,
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        c.setMarkedText(attr,
                        selectionRange: NSRange(location: text.utf16.count, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func clearMarked() {
        guard let c = currentClient() else { return }
        c.setMarkedText(NSAttributedString(string: ""),
                        selectionRange: NSRange(location: 0, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func commit(_ text: String) {
        currentClient()?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        reset()
    }

    private func reset() {
        englishBuffer = ""
        previewMandarin = nil
        pending = false
        attempted = false
    }

    // MARK: Event handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else { return false }

        // Never intercept command-key shortcuts (Cmd-C, Cmd-Space, etc.).
        if event.modifierFlags.contains(.command) { return false }

        switch event.keyCode {
        case kReturn, kKeypadEnter:
            return handleReturn()
        case kEscape:
            return handleEscape()
        case kDelete:
            return handleDelete()
        default:
            return handleText(event)
        }
    }

    private func handleReturn() -> Bool {
        if let mandarin = previewMandarin {
            commit(mandarin)                 // accept translation; does NOT send
            return true
        }
        if !englishBuffer.isEmpty {
            if attempted {
                // Translation already tried and produced no preview (both engines
                // failed): let the user send their English rather than get stuck.
                commit(englishBuffer)
                return true
            }
            triggerTranslation()             // translate now; don't send yet
            return true
        }
        return false                         // nothing composing → app handles Enter (send)
    }

    private func handleEscape() -> Bool {
        if previewMandarin != nil {
            previewMandarin = nil
            attempted = false
            showMarked(englishBuffer)        // back to editing English
            return true
        }
        if !englishBuffer.isEmpty {
            reset()
            clearMarked()
            return true
        }
        return false
    }

    private func handleDelete() -> Bool {
        if previewMandarin != nil {
            previewMandarin = nil            // drop preview, resume editing English
            attempted = false
            showMarked(englishBuffer)
            return true
        }
        if !englishBuffer.isEmpty {
            englishBuffer.removeLast()
            attempted = false
            if englishBuffer.isEmpty { clearMarked() } else { showMarked(englishBuffer) }
            return true
        }
        return false
    }

    private func handleText(_ event: NSEvent) -> Bool {
        guard let chars = event.characters, !chars.isEmpty else { return false }

        // Ignore function/arrow keys (Unicode private-use range) and control chars —
        // let the app handle them rather than injecting them into the buffer.
        if let first = chars.unicodeScalars.first, first.value >= 0xF700 { return false }
        if chars.unicodeScalars.allSatisfy({ $0.value < 0x20 || $0.value == 0x7F }) { return false }

        // Typing after a preview starts a fresh sentence.
        if previewMandarin != nil {
            previewMandarin = nil
            englishBuffer = ""
        }
        attempted = false
        englishBuffer += chars
        showMarked(englishBuffer)

        // Early trigger: sentence-ending punctuation preceded by a letter
        // (so "3.5", "12!" etc. don't mis-fire).
        if chars.count == 1, let last = chars.first, ".?!".contains(last),
           let before = englishBuffer.dropLast().last, before.isLetter {
            triggerTranslation()
        }
        return true
    }

    private func triggerTranslation() {
        let source = englishBuffer
        guard !source.isEmpty, !pending else { return }
        pending = true
        Task { @MainActor in
            let result = try? await self.engine.translate(source, to: self.target)
            self.pending = false
            // Discard if the buffer changed while translating.
            guard self.englishBuffer == source else { return }
            self.attempted = true
            if let mandarin = result, !mandarin.isEmpty {
                self.previewMandarin = mandarin
                self.showMarked(mandarin)
            }
            // On failure, leave the English underlined; Enter will then send it.
        }
    }

    // Focus is leaving the field — flush whatever we have as real text so it
    // isn't silently lost.
    override func commitComposition(_ sender: Any!) {
        if let mandarin = previewMandarin {
            commit(mandarin)
        } else if !englishBuffer.isEmpty {
            commit(englishBuffer)
        }
    }

    // MARK: Input-source menu

    /// Shown in the macOS text-input (menu-bar flag) menu while we're active.
    override func menu() -> NSMenu! {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Type Translator Settings…",
                              action: #selector(openSettings),
                              keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }
}

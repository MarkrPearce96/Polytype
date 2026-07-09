import AppKit
import Carbon
import TranslationCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var service: TranslateService!
    private let defaultTitle = "譯"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build the same engine the input-method version used: DeepL primary,
        // Apple on-device fallback (macOS 15+).
        let secrets = KeychainSecretStore()
        let deepl = DeepLEngine(secrets: secrets, http: URLSessionHTTPClient())
        let engine: TranslationEngine
        if #available(macOS 15, *) {
            engine = FallbackChain(primary: deepl, fallback: AppleEngine())
        } else {
            engine = deepl
        }
        service = TranslateService(engine: engine)

        // Menu-bar item.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = defaultTitle
        service.onStatus = { [weak self] glyph in
            guard let self else { return }
            self.statusItem.button?.title = glyph.isEmpty ? self.defaultTitle : glyph
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Translate what I typed  (⌥⌘T)",
                     action: #selector(translateNow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Type Translator", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu

        // Global hotkey: ⌥⌘T.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_T),
                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.translateNow()
        }

        // Ask for Accessibility up front so the first hotkey press isn't a no-op.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @objc private func translateNow() {
        service.translateSelectionInPlace()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

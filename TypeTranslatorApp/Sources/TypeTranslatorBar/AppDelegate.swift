import AppKit
import TranslationCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lastEngineItem: NSMenuItem!
    private var translateItem: NSMenuItem!
    private var service: TranslateService!
    private let defaultTitle = "譯"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Google Cloud Translation primary (free 500k chars/month), Apple
        // on-device as the offline/no-key fallback (macOS 15+).
        let secrets = KeychainSecretStore()
        let http = URLSessionHTTPClient()
        let google = GoogleEngine(secrets: secrets, http: http)
        let flag = FallbackFlag()
        let engine: TranslationEngine
        if #available(macOS 15, *) {
            let chain = FallbackChain(primary: google, fallback: AppleEngine())
            chain.onFallback = { _ in flag.value = true }   // Google failed → Apple used
            engine = chain
        } else {
            engine = google
        }
        service = TranslateService(engine: engine, fallbackFlag: flag)

        // Menu-bar item — our app icon, with a transient status glyph beside it
        // during a translation ("…", "✓", "⚠").
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let hasIcon = installMenuBarIcon()
        if !hasIcon { statusItem.button?.title = defaultTitle }
        service.onStatus = { [weak self] glyph in
            guard let self else { return }
            if hasIcon {
                self.statusItem.button?.title = glyph          // "" clears it
            } else {
                self.statusItem.button?.title = glyph.isEmpty ? self.defaultTitle : glyph
            }
        }

        let menu = NSMenu()
        translateItem = NSMenuItem(title: "Translate what I typed  (\(HotkeyController.shared.display))",
                                   action: #selector(translateNow), keyEquivalent: "")
        menu.addItem(translateItem)
        menu.addItem(.separator())
        lastEngineItem = NSMenuItem(title: "Last translation: —", action: nil, keyEquivalent: "")
        lastEngineItem.isEnabled = false
        menu.addItem(lastEngineItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Type Translator", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu

        service.onEngineUsed = { [weak self] name in
            self?.lastEngineItem.title = "Last translation: \(name)"
        }

        // Global hotkey (default ⌥⌘T; changeable in Settings).
        HotkeyController.shared.action = { [weak self] in self?.translateNow() }
        HotkeyController.shared.onChange = { [weak self] display in
            self?.translateItem.title = "Translate what I typed  (\(display))"
        }
        HotkeyController.shared.register()

        // Ask for Accessibility up front so the first hotkey press isn't a no-op.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Put our colored app icon in the menu bar. Returns false if the image
    /// isn't found (then we fall back to the 譯 text label).
    private func installMenuBarIcon() -> Bool {
        guard let image = NSImage(named: "menubar") else { return false }
        image.isTemplate = false            // keep the colored icon (not tinted)
        image.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeft
        return true
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

import AppKit
import Carbon
import TranslationCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lastEngineItem: NSMenuItem!
    private var translateItem: NSMenuItem!
    private var service: TranslateService!
    private let defaultTitle = "譯"
    private var composeHotkey: HotkeyController!
    private var readHotkey: HotkeyController!
    private var readItem: NSMenuItem!

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

        // Both hotkeys are created before the menu below, since the menu items
        // display each one's current combo.
        composeHotkey = HotkeyController(id: "compose",
            defaultKeyCode: UInt32(kVK_ANSI_T), defaultModifiers: UInt32(cmdKey | optionKey), defaultDisplay: "⌥⌘T")
        // Temporary bridge — SettingsWindow.swift still targets
        // HotkeyController.shared until Task 5 rewires it. Remove in Task 5.
        HotkeyController.shared = composeHotkey
        readHotkey = HotkeyController(id: "read",
            defaultKeyCode: UInt32(kVK_ANSI_R), defaultModifiers: UInt32(cmdKey | optionKey), defaultDisplay: "⌥⌘R")

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
        translateItem = NSMenuItem(title: "Translate what I typed  (\(composeHotkey.display))",
                                   action: #selector(translateNow), keyEquivalent: "")
        menu.addItem(translateItem)
        readItem = NSMenuItem(title: "Translate selection to English  (\(readHotkey.display))",
                              action: #selector(readNow), keyEquivalent: "")
        menu.addItem(readItem)
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

        // Global hotkeys (defaults ⌥⌘T / ⌥⌘R; changeable in Settings).
        composeHotkey.action = { [weak self] in self?.translateNow() }
        composeHotkey.onChange = { [weak self] d in self?.translateItem.title = "Translate what I typed  (\(d))" }
        composeHotkey.register()

        readHotkey.action = { [weak self] in self?.readNow() }
        readHotkey.onChange = { [weak self] d in self?.readItem.title = "Translate selection to English  (\(d))" }
        readHotkey.register()

        // Ask for Accessibility up front so the first hotkey press isn't a no-op.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Put our colored app icon in the menu bar. Returns false if the image
    /// isn't found (then we fall back to the 譯 text label).
    private func installMenuBarIcon() -> Bool {
        // Menu-bar icons must be TEMPLATE images so macOS renders them adaptively
        // (black on light menu bars, white on dark) and they stay visible on any
        // wallpaper — a colored icon disappears, like every other menu-bar glyph.
        // The colorful globe remains the app (Finder/Dock) icon. We use the system
        // "globe" symbol directly, which is already a crisp template at any size.
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard let icon = NSImage(systemSymbolName: "globe", accessibilityDescription: "Type Translator")?
            .withSymbolConfiguration(config) else { return false }
        icon.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeft
        return true
    }

    @objc private func translateNow() {
        service.translateSelectionInPlace()
    }

    /// Temporary stub — replaced with real read-translation behavior in Task 4.
    @objc private func readNow() {
        ResultPopup.shared.show("Read hotkey works", at: NSEvent.mouseLocation)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

import AppKit
import Carbon
import TranslationCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var engineDotView: NSView!
    private var engineLabel: NSTextField!
    private var lastEngineUsed: String?
    private let networkMonitor = NetworkMonitor()
    private var translateItem: NSMenuItem!
    private var service: TranslateService!
    private let defaultTitle = "譯"
    private var composeHotkey: HotkeyController!
    private var readHotkey: HotkeyController!
    private var readItem: NSMenuItem!
    private var composeLangMenu: NSMenu!
    private var readLangMenu: NSMenu!
    private var composeStatusLabel: NSTextField!
    private var readStatusLabel: NSTextField!

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
        readHotkey = HotkeyController(id: "read",
            defaultKeyCode: UInt32(kVK_ANSI_R), defaultModifiers: UInt32(cmdKey | optionKey), defaultDisplay: "⌥⌘R")
        HotkeyAccess.compose = composeHotkey
        HotkeyAccess.read = readHotkey

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

        // Header: identity + a live at-a-glance summary of both directions.
        let headerItem = NSMenuItem()
        headerItem.view = buildMenuHeader()
        menu.addItem(headerItem)
        menu.addItem(.separator())

        // Actions (language shown in the header, so titles stay short).
        translateItem = NSMenuItem(title: "Translate what I typed  (\(composeHotkey.display))",
                                   action: #selector(translateNow), keyEquivalent: "")
        translateItem.image = symbol("character.cursor.ibeam")
        menu.addItem(translateItem)
        readItem = NSMenuItem(title: "Read selection  (\(readHotkey.display))",
                              action: #selector(readNow), keyEquivalent: "")
        readItem.image = symbol("text.viewfinder")
        menu.addItem(readItem)

        menu.addItem(.separator())

        composeLangMenu = NSMenu()
        for lang in Languages.all {
            let item = NSMenuItem(title: lang.name, action: #selector(selectComposeLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang.code
            item.target = self
            composeLangMenu.addItem(item)
        }
        let composeLangItem = NSMenuItem(title: "Compose language", action: nil, keyEquivalent: "")
        composeLangItem.image = symbol("globe")
        composeLangItem.submenu = composeLangMenu
        menu.addItem(composeLangItem)

        readLangMenu = NSMenu()
        let autoItem = NSMenuItem(title: "Auto-detect", action: #selector(selectReadLanguage(_:)), keyEquivalent: "")
        autoItem.representedObject = Languages.autoCode
        autoItem.target = self
        readLangMenu.addItem(autoItem)
        readLangMenu.addItem(.separator())
        for lang in Languages.all {
            let item = NSMenuItem(title: lang.name, action: #selector(selectReadLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang.code
            item.target = self
            readLangMenu.addItem(item)
        }
        let readLangItem = NSMenuItem(title: "Read language", action: nil, keyEquivalent: "")
        readLangItem.image = symbol("character.bubble")
        readLangItem.submenu = readLangMenu
        menu.addItem(readLangItem)

        menu.addItem(.separator())
        let engineStatusItem = NSMenuItem()
        engineStatusItem.view = buildEngineStatusView()
        menu.addItem(engineStatusItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.image = symbol("gearshape")
        menu.addItem(settingsItem)
        let quitItem = NSMenuItem(title: "Quit Type Translator", action: #selector(quit), keyEquivalent: "q")
        quitItem.image = symbol("power")
        menu.addItem(quitItem)
        for item in menu.items where item.action != nil { item.target = self }
        menu.delegate = self
        statusItem.menu = menu

        service.onEngineUsed = { [weak self] name in
            self?.lastEngineUsed = name
            self?.updateEngineStatus()
        }

        // Global hotkeys (defaults ⌥⌘T / ⌥⌘R; changeable in Settings).
        composeHotkey.action = { [weak self] in self?.translateNow() }
        composeHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
        composeHotkey.register()

        readHotkey.action = { [weak self] in self?.readNow() }
        readHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
        readHotkey.register()

        // Ask for Accessibility up front so the first hotkey press isn't a no-op.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

        refreshLanguageMenus()
        updateEngineStatus()

        // Offline, auto-detect Read can't work (Apple can't detect a language), so
        // switch to a specific language while offline and restore auto when back.
        networkMonitor.onChange = { [weak self] online in self?.handleNetworkChange(online: online) }
        networkMonitor.start()
    }

    private func handleNetworkChange(online: Bool) {
        if !online {
            // Offline: auto-detect can't work, so translate from the last specific
            // language via a temporary override (the saved preference is untouched).
            if LanguagePrefs.readSourceCode == Languages.autoCode {
                LanguagePrefs.readSourceOverride = LanguagePrefs.lastSpecificReadCode
            }
        } else {
            // Back online: drop any offline override, and clear a stale failure so
            // the light doesn't stay orange after connectivity returns.
            LanguagePrefs.readSourceOverride = nil
            if lastEngineUsed == "failed" { lastEngineUsed = nil }
        }
        refreshLanguageMenus()
        updateEngineStatus()
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

    @objc private func readNow() {
        service.translateSelectionToPopup()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func selectComposeLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        LanguagePrefs.composeTargetCode = code
        refreshLanguageMenus()
    }

    @objc private func selectReadLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        LanguagePrefs.readSourceCode = code
        LanguagePrefs.readSourceOverride = nil   // deliberate choice wins over any offline override
        if code != Languages.autoCode { LanguagePrefs.lastSpecificReadCode = code }
        refreshLanguageMenus()
    }

    /// Sync submenu checkmarks, the two action titles, and the header's live
    /// direction summary to the current selections. Single source of truth for all.
    private func refreshLanguageMenus() {
        let compose = LanguagePrefs.composeTargetCode
        let read = LanguagePrefs.effectiveReadSourceCode
        for item in composeLangMenu.items {
            item.state = (item.representedObject as? String == compose) ? .on : .off
        }
        for item in readLangMenu.items {
            item.state = (item.representedObject as? String == read) ? .on : .off
        }
        translateItem.title = "Translate what I typed  (\(composeHotkey.display))"
        readItem.title = "Read selection  (\(readHotkey.display))"
        composeStatusLabel?.stringValue = "Compose   English → \(shortLang(compose))"
        readStatusLabel?.stringValue = "Read   \(shortLang(read)) → English"
    }

    /// Native display name without the trailing "(English name)" annotation.
    private func shortLang(_ code: String) -> String {
        let full = Languages.name(for: code)
        return String(full.split(separator: " (").first ?? Substring(full))
    }

    /// A non-interactive status row: a colored dot (green = Google active,
    /// gray = Apple on-device) plus a label. View-based so the dot stays vivid.
    private func buildEngineStatusView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 24))

        engineDotView = NSView()
        engineDotView.wantsLayer = true
        engineDotView.layer?.cornerRadius = 4.5
        engineDotView.translatesAutoresizingMaskIntoConstraints = false

        engineLabel = NSTextField(labelWithString: "")
        engineLabel.font = .systemFont(ofSize: 12)
        engineLabel.textColor = .secondaryLabelColor
        engineLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(engineDotView)
        container.addSubview(engineLabel)
        NSLayoutConstraint.activate([
            engineDotView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            engineDotView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            engineDotView.widthAnchor.constraint(equalToConstant: 9),
            engineDotView.heightAnchor.constraint(equalToConstant: 9),
            engineLabel.leadingAnchor.constraint(equalTo: engineDotView.trailingAnchor, constant: 8),
            engineLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// Reflect the active translation engine: green + "Google" when Google is
    /// in use (last translation used it, or a key is set and none has run yet),
    /// gray + "Apple on-device" when the fallback is in effect or no key is set.
    private func updateEngineStatus() {
        let hasKey = !(KeychainSecretStore().get(googleKeyName) ?? "").isEmpty
        let online = networkMonitor.isOnline
        let color: NSColor
        let text: String
        switch lastEngineUsed {
        case "failed":
            // Distinguish "can't reach anything" from an online failure (bad key, etc.).
            color = .systemOrange; text = online ? "Translation failed" : "No connection"
        case "apple":
            color = .systemGray; text = "Apple on-device"          // working via the on-device engine
        default:
            // "google", or nothing run yet.
            if !hasKey       { color = .systemGray;   text = "Apple on-device" }   // no key → Apple only
            else if !online  { color = .systemOrange; text = "No connection" }     // key set but offline
            else             { color = .systemGreen;  text = "Google — active" }
        }
        engineDotView?.layer?.backgroundColor = color.cgColor
        engineLabel?.stringValue = text
    }

    /// A template SF Symbol sized for a menu-item icon.
    private func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// A non-interactive header view for the top of the menu: the brand globe,
    /// the app name, and a live summary of the compose/read directions.
    private func buildMenuHeader() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 64))

        let globe = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        globe.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        globe.contentTintColor = NSColor(srgbRed: 122/255, green: 100/255, blue: 246/255, alpha: 1)
        globe.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Type Translator")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        composeStatusLabel = NSTextField(labelWithString: "")
        composeStatusLabel.font = .systemFont(ofSize: 11)
        composeStatusLabel.textColor = .secondaryLabelColor
        readStatusLabel = NSTextField(labelWithString: "")
        readStatusLabel.font = .systemFont(ofSize: 11)
        readStatusLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [title, composeStatusLabel, readStatusLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(globe)
        container.addSubview(textStack)
        NSLayoutConstraint.activate([
            globe.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            globe.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            globe.widthAnchor.constraint(equalToConstant: 26),
            globe.heightAnchor.constraint(equalToConstant: 26),
            textStack.leadingAnchor.constraint(equalTo: globe.trailingAnchor, constant: 11),
            textStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])
        return container
    }
}

extension AppDelegate: NSMenuDelegate {
    // Refresh the engine light when the menu opens, so a just-saved API key shows
    // as green without waiting for the next translation. Menus open on the main
    // thread, so assuming main-actor isolation here is safe.
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { updateEngineStatus() }
    }
}

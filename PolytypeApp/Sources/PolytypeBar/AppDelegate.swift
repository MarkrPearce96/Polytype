import AppKit
import Carbon
import TranslationCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lastEngineUsed: String?
    private let networkMonitor = NetworkMonitor()
    private var service: TranslateService!
    private var usageMeter: UsageMeter?
    private let defaultTitle = "譯"
    private var composeHotkey: HotkeyController!
    private var readHotkey: HotkeyController!
    private var previewHotkey: HotkeyController!
    private var composeLangMenu: NSMenu!
    private var readLangMenu: NSMenu!
    private var composeCard: MenuCardView!
    private var readCard: MenuCardView!
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var statusCount: NSTextField!
    private var statusBar: MenuMeterBar!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Google Cloud Translation primary (free 500k chars/month), Apple
        // on-device as the offline/no-key fallback (macOS 15+).
        let secrets = KeychainSecretStore()
        let http = URLSessionHTTPClient()
        let google = GoogleEngine(secrets: secrets, http: http)
        let meter = UsageMeter(store: UserDefaultsUsageStore(), now: { Date() })
        usageMeter = meter
        MeterAccess.meter = meter
        let gated = QuotaGate(primary: google, meter: meter)
        let flag = FallbackFlag()
        let engine: TranslationEngine
        if #available(macOS 15, *) {
            let chain = FallbackChain(primary: gated, fallback: AppleEngine())
            chain.onFallback = { [weak self] error in
                flag.value = true   // Google failed → Apple used
                if error == .quotaExceeded { Task { @MainActor in self?.handleQuotaReached() } }
            }
            engine = chain
        } else {
            engine = gated   // macOS 14: no Apple fallback; over-cap fails closed (never charged)
        }
        var backEngine: TranslationEngine? = nil
        if #available(macOS 15, *) { backEngine = AppleEngine() }
        service = TranslateService(engine: engine, fallbackFlag: flag, backTranslateEngine: backEngine)

        // Both hotkeys are created before the menu below, since the menu items
        // display each one's current combo.
        composeHotkey = HotkeyController(id: "compose",
            defaultKeyCode: UInt32(kVK_ANSI_T), defaultModifiers: UInt32(cmdKey | optionKey), defaultDisplay: "⌥⌘T")
        readHotkey = HotkeyController(id: "read",
            defaultKeyCode: UInt32(kVK_ANSI_R), defaultModifiers: UInt32(cmdKey | optionKey), defaultDisplay: "⌥⌘R")
        HotkeyAccess.compose = composeHotkey
        HotkeyAccess.read = readHotkey
        previewHotkey = HotkeyController(id: "preview",
            defaultKeyCode: UInt32(kVK_ANSI_T),
            defaultModifiers: UInt32(cmdKey | optionKey | shiftKey), defaultDisplay: "⌥⇧⌘T")
        HotkeyAccess.preview = previewHotkey

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

        // Two direction cards. Each owns its language list as a submenu — hovering
        // the card opens it. Translation itself is hotkey-driven.
        composeLangMenu = NSMenu()
        for lang in Languages.all {
            let item = NSMenuItem(title: lang.name, action: #selector(selectComposeLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang.code
            item.target = self
            composeLangMenu.addItem(item)
        }
        composeCard = MenuCardView(caption: "Compose", shortcut: composeHotkey.display)
        let composeItem = NSMenuItem()
        composeItem.view = composeCard
        composeItem.submenu = composeLangMenu
        menu.addItem(composeItem)

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
        readCard = MenuCardView(caption: "Read", shortcut: readHotkey.display)
        let readCardItem = NSMenuItem()
        readCardItem.view = readCard
        readCardItem.submenu = readLangMenu
        menu.addItem(readCardItem)

        menu.addItem(.separator())
        let statusRowItem = NSMenuItem()
        statusRowItem.view = buildStatusRow()
        menu.addItem(statusRowItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)
        let setupItem = NSMenuItem(title: "Setup Assistant…", action: #selector(openSetup), keyEquivalent: "")
        menu.addItem(setupItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(quitItem)

        for item in menu.items where item.action != nil { item.target = self }
        menu.delegate = self
        statusItem.menu = menu

        service.onEngineUsed = { [weak self] name in
            self?.lastEngineUsed = name
            self?.updateStatusRow()
        }

        // Global hotkeys (defaults ⌥⌘T / ⌥⌘R / ⌥⇧⌘T; changeable in Settings).
        composeHotkey.action = { [weak self] in self?.translateNow() }
        composeHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
        readHotkey.action = { [weak self] in self?.readNow() }
        readHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
        previewHotkey.action = { [weak self] in self?.previewNow() }
        previewHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
        PreviewControl.onSettingsChanged = { [weak self] in self?.applyHotkeyRegistration() }
        applyHotkeyRegistration()

        // Ask for Accessibility up front so the first hotkey press isn't a no-op.
        // First-run users get this from the setup wizard's Accessibility step instead,
        // so we don't show two prompts back to back.
        if SetupState.completed {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        refreshLanguageMenus()
        updateStatusRow()

        // Offline, auto-detect Read can't work (Apple can't detect a language), so
        // switch to a specific language while offline and restore auto when back.
        networkMonitor.onChange = { [weak self] online in self?.handleNetworkChange(online: online) }
        networkMonitor.start()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if !SetupState.completed {
            SetupWindowController.shared.show()
        }
    }

    /// First time the monthly cap is hit, tell the user we've switched to Apple.
    private func handleQuotaReached() {
        guard let meter = usageMeter, !meter.hasNotified else { return }
        meter.markNotified()
        updateStatusRow()

        let content = UNMutableNotificationContent()
        content.title = "Google free limit reached"
        content.body = "Using Apple on-device translation until \(MeterAccess.resetDateString())."
        let request = UNNotificationRequest(identifier: "quota.reached", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Compact character count, e.g. 42300 → "42k".
    private func shortCount(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k" : "\(n)"
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
        updateStatusRow()
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
        guard let icon = NSImage(systemSymbolName: "globe", accessibilityDescription: "Polytype")?
            .withSymbolConfiguration(config) else { return false }
        icon.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeft
        return true
    }

    /// The Compose action (hotkey + menu item). Routes to preview only when preview
    /// is enabled AND set to take over the Compose hotkey; otherwise instant.
    @objc private func translateNow() {
        if LanguagePrefs.previewEnabled && LanguagePrefs.previewUsesComposeHotkey {
            service.translateSelectionWithPreview()
        } else {
            service.translateSelectionInPlace()
        }
    }

    /// The dedicated preview action (separate preview hotkey).
    @objc private func previewNow() {
        service.translateSelectionWithPreview()
    }

    /// (Re)apply hotkey registration for the current preview settings. Compose and
    /// Read are always registered (Compose routes internally); the separate preview
    /// hotkey is registered only when preview is on and NOT taking over Compose.
    private func applyHotkeyRegistration() {
        composeHotkey.register()
        readHotkey.register()
        if LanguagePrefs.previewEnabled && !LanguagePrefs.previewUsesComposeHotkey {
            previewHotkey.register()
        } else {
            previewHotkey.unregister()
        }
    }

    @objc private func readNow() {
        service.translateSelectionToPopup()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openSetup() {
        SetupWindowController.shared.show()
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

    /// Sync submenu checkmarks and both direction cards to the current selections.
    private func refreshLanguageMenus() {
        let compose = LanguagePrefs.composeTargetCode
        let read = LanguagePrefs.effectiveReadSourceCode
        for item in composeLangMenu.items {
            item.state = (item.representedObject as? String == compose) ? .on : .off
        }
        for item in readLangMenu.items {
            item.state = (item.representedObject as? String == read) ? .on : .off
        }
        composeCard?.shortcut = composeHotkey.display
        readCard?.shortcut = readHotkey.display
        composeCard?.direction = "English → \(shortLang(compose))"
        readCard?.direction = "\(shortLang(read)) → English"
        composeCard?.needsDisplay = true
        readCard?.needsDisplay = true
    }

    /// Native display name without the trailing "(English name)" annotation.
    private func shortLang(_ code: String) -> String {
        let full = Languages.name(for: code)
        return String(full.split(separator: " (").first ?? Substring(full))
    }

    /// The merged status row: a dot + engine/state text + usage count on one line,
    /// with a full-width meter beneath ("Variant 2" — long states never truncate).
    private func buildStatusRow() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 292, height: 42))

        statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusCount = NSTextField(labelWithString: "")
        statusCount.font = .systemFont(ofSize: 11)
        statusCount.textColor = .secondaryLabelColor
        statusCount.alignment = .right
        statusCount.translatesAutoresizingMaskIntoConstraints = false

        statusBar = MenuMeterBar(frame: .zero)   // designated init — MenuMeterBar has no parameterless init
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(statusDot)
        container.addSubview(statusLabel)
        container.addSubview(statusCount)
        container.addSubview(statusBar)
        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            statusDot.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            statusCount.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),
            statusCount.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            statusCount.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            statusBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 7),
            statusBar.heightAnchor.constraint(equalToConstant: 4),
        ])
        return container
    }

    /// Single source of truth for the status row. Branch order matters: the capped
    /// state wins over everything, because it's how the user learns they've been
    /// moved to Apple to avoid a charge — it must never be hidden or truncated.
    private func updateStatusRow() {
        guard let meter = usageMeter else { return }
        let used = meter.used
        statusBar?.fraction = CGFloat(min(used, meter.limit)) / CGFloat(meter.limit)

        if meter.hasNotified || used >= meter.cap {
            statusDot?.layer?.backgroundColor = NSColor.systemGray.cgColor
            statusLabel?.stringValue = "Free limit reached — on Apple until \(MeterAccess.resetDateString())"
            // Clear the text as well as hiding it: a hidden NSTextField keeps the
            // intrinsic width of its stringValue, and its leading constraint stays
            // active — a stale count would reserve space and truncate this message,
            // which is the one string that must always be readable in full.
            statusCount?.stringValue = ""
            statusCount?.isHidden = true
            statusBar?.fraction = 1
            statusBar?.isSpent = true
            return
        }
        statusCount?.isHidden = false
        statusCount?.stringValue = "≈\(shortCount(used)) / \(shortCount(meter.limit))"
        statusBar?.isSpent = false

        let hasKey = !(KeychainSecretStore().get(googleKeyName) ?? "").isEmpty
        let online = networkMonitor.isOnline
        let color: NSColor
        let text: String
        switch lastEngineUsed {
        case "failed":
            // Distinguish "can't reach anything" from an online failure (bad key, etc.).
            color = .systemOrange; text = online ? "Translation failed" : "No connection"
        case "apple":
            color = .systemGray; text = "Apple on-device"
        default:
            if !hasKey       { color = .systemGray;   text = "Apple on-device" }
            else if !online  { color = .systemOrange; text = "No connection" }
            else             { color = .systemGreen;  text = "Google — active" }
        }
        statusDot?.layer?.backgroundColor = color.cgColor
        statusLabel?.stringValue = text
    }
}

extension AppDelegate: NSMenuDelegate {
    // Refresh the status row when the menu opens, so a just-saved API key shows
    // as green without waiting for the next translation. Menus open on the main
    // thread, so assuming main-actor isolation here is safe.
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            updateStatusRow()
        }
    }
}

import AppKit
import Carbon
import SwiftUI
import TranslationCore
import UserNotifications

/// TEMPORARY — traces launch/hotkey-firing on a genuinely fresh install.
/// Remove once found.
func launchdbg(_ message: String) {
    let line = "[LAUNCH] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = "/tmp/polytype-launch-debug.log"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let networkMonitor = NetworkMonitor()
    private var service: TranslateService!
    private var usageMeter: UsageMeter?
    private let defaultTitle = "譯"
    private var composeHotkey: HotkeyController!
    private var readHotkey: HotkeyController!
    /// The single floating panel — replaces the native `NSMenu` dropdown so
    /// Settings can swap in as this same panel's content (see `openSettings`)
    /// instead of needing a second window that can only ever guess at where
    /// the first one was.
    private var dropdown: DropdownPanel!
    private var menuStack: VerticalRowStack!
    private var health: GoogleHealthMonitor!
    private var languageMenu: LanguageMenuController!

    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var statusCount: NSTextField!
    private var statusBar: MenuMeterBar!

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchdbg("applicationDidFinishLaunching START")
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
        service = TranslateService(engine: engine, fallbackFlag: flag)

        // A fresh launch prefers Auto-detect over carrying a manual pick from
        // last session forward — but only when Google looks reachable (offline,
        // Auto-detect can't work anyway, so leave whatever was there).
        // `networkMonitor.isOnline` defaults true until the first real path
        // update arrives, which is the right optimistic assumption here too.
        if networkMonitor.isOnline {
            LanguagePrefs.readSourceCode = Languages.autoCode
            LanguagePrefs.readSourceOverride = nil
            LanguagePrefs.composeSourceCode = Languages.autoCode
            LanguagePrefs.composeSourceOverride = nil
        }

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

        dropdown = DropdownPanel()
        dropdown.onWillShow = { [weak self] in self?.updateStatusRow() }
        dropdown.onDidHide = { [weak self] in
            self?.languageMenu.collapse()
            // Reset to the menu so a fresh click on the status icon always
            // starts there, even if Settings was showing when this closed
            // (e.g. the user clicked away while looking at Settings).
            if let self, let stack = self.menuStack { self.dropdown.setContent(stack) }
        }

        let rowWidth: CGFloat = 292
        menuStack = VerticalRowStack(frame: .zero)
        menuStack.rowWidth = rowWidth

        health = GoogleHealthMonitor(networkMonitor: networkMonitor)
        health.onChange = { [weak self] in self?.languageMenu.refreshLanguageMenus() }
        languageMenu = LanguageMenuController(menuStack: menuStack, dropdown: dropdown,
                                               composeHotkey: composeHotkey, readHotkey: readHotkey, health: health)

        let settingsRow = FooterRow(title: "⚙ Settings…", hint: "⌘,", width: rowWidth)
        settingsRow.target = self
        settingsRow.action = #selector(openSettings)
        let quitRow = FooterRow(title: "Quit", hint: "⌘Q", width: rowWidth)
        quitRow.target = self
        quitRow.action = #selector(quit)

        menuStack.setRows([
            languageMenu.composeCard,
            languageMenu.readCard,
            SeparatorRow(width: rowWidth),
            buildStatusRow(),
            SeparatorRow(width: rowWidth),
            settingsRow,
            quitRow,
        ])
        launchdbg("menuStack.setRows count=\(menuStack.rows.count)")
        dropdown.setContent(menuStack)
        launchdbg("dropdown.setContent(menuStack) done")

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)

        service.onEngineUsed = { [weak self] name in
            self?.health.recordEngineUsed(name)
            self?.updateStatusRow()
        }

        // Global hotkeys (defaults ⌥⌘T / ⌥⌘R; changeable in Settings).
        composeHotkey.action = { [weak self] in self?.translateNow() }
        composeHotkey.onChange = { [weak self] _ in self?.languageMenu.refreshLanguageMenus() }
        readHotkey.action = { [weak self] in self?.readNow() }
        readHotkey.onChange = { [weak self] _ in self?.languageMenu.refreshLanguageMenus() }
        applyHotkeyRegistration()

        // Ask for Accessibility up front so the first hotkey press isn't a no-op.
        // First-run users get this from the setup wizard's Accessibility step instead,
        // so we don't show two prompts back to back.
        if SetupState.completed {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        languageMenu.refreshLanguageMenus()
        updateStatusRow()

        // Offline, auto-detect Read can't work (Apple can't detect a language), so
        // switch to a specific language while offline and restore auto when back.
        networkMonitor.onChange = { [weak self] online in self?.handleNetworkChange(online: online) }
        networkMonitor.start()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if !SetupState.completed {
            SetupWindowController.shared.show()
        }
        launchdbg("applicationDidFinishLaunching END")
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
        health.recordNetworkChange(online: online)
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

    /// The Compose action (hotkey + menu item).
    @objc private func translateNow() {
        launchdbg("translateNow() fired")
        service.translateSelectionInPlace()
    }

    private func applyHotkeyRegistration() {
        let composeOK = composeHotkey.register()
        let readOK = readHotkey.register()
        launchdbg("applyHotkeyRegistration compose=\(composeOK) read=\(readOK)")
    }

    @objc private func readNow() {
        launchdbg("readNow() fired")
        service.translateSelectionToPopup()
    }

    /// The timestamp of the last click this actually acted on — guards
    /// against the same physical click on the status item being redelivered
    /// a second time (traced empirically: this can arrive anywhere from
    /// immediately up to several seconds later), which would otherwise
    /// toggle the panel again at a moment unrelated to anything the user is
    /// currently doing.
    private var lastStatusClickTimestamp: TimeInterval = 0

    @objc private func statusItemClicked() {
        let timestamp = NSApp.currentEvent?.timestamp ?? 0
        guard timestamp != lastStatusClickTimestamp else { return }
        lastStatusClickTimestamp = timestamp
        launchdbg("statusItemClicked, menuStack.rows.count=\(menuStack.rows.count), dropdown.isVisible=\(dropdown.isVisible)")
        dropdown.toggle(near: statusItem.button)
    }

    /// Swaps the panel's content to Settings, in place — not a separate
    /// window, so there's nothing to position or keep in sync with where the
    /// menu happened to be.
    @objc private func openSettings() {
        let hosting = NSHostingView(rootView: SettingsView(onBack: { [weak self] in
            guard let self, let stack = self.menuStack else { return }
            self.dropdown.setContent(stack)
        }))
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 520)
        dropdown.setContent(hosting)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
        switch health.lastEngineUsed {
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

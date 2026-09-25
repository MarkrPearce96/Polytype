import AppKit
import Carbon
import SwiftUI
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
    /// The single floating panel — replaces the native `NSMenu` dropdown so
    /// Settings can swap in as this same panel's content (see `openSettings`)
    /// instead of needing a second window that can only ever guess at where
    /// the first one was.
    private var dropdown: DropdownPanel!
    private var menuStack: VerticalRowStack!

    /// The four independently-editable language fields, each with its own
    /// inline row list, its own click target (a `DirectionChip` inside the
    /// owning card), and its own anchor row it's inserted below when
    /// expanded — since a single list can't disambiguate "which of this
    /// card's two fields am I changing."
    private enum Field { case composeSource, composeTarget, readSource, readTarget }
    private var fieldItems: [Field: [LanguageRow]] = [:]
    private var expandedField: Field?
    /// Exactly the rows currently inserted into `menuStack` for
    /// `expandedField` — a filtered subset of `fieldItems[expandedField]`
    /// (the language already chosen on the other side of the same card is
    /// left out), tracked separately so collapse only ever removes rows that
    /// are actually there.
    private var expandedItems: [LanguageRow] = []

    /// Which curated languages currently have their on-device pack installed,
    /// checked against English (the common pairing) — nil until computed.
    /// Populated lazily while relying on Apple (see `reconcileGoogleHealth`)
    /// so the pickers can filter to only what's actually usable right now;
    /// left nil (no filtering) while Google's healthy, since Google can
    /// translate any pair with nothing to download.
    private var installedLanguageCodes: Set<String>?

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
            self?.collapse()
            // Reset to the menu so a fresh click on the status icon always
            // starts there, even if Settings was showing when this closed
            // (e.g. the user clicked away while looking at Settings).
            if let self, let stack = self.menuStack { self.dropdown.setContent(stack) }
        }

        let rowWidth: CGFloat = 292
        menuStack = VerticalRowStack(frame: .zero)
        menuStack.rowWidth = rowWidth

        // Two direction cards, each with an independent source and target
        // field. Both fields on both cards may be Auto-detect on the source
        // side; clicking either field's name expands just that field's list
        // inline below the card. Translation itself is hotkey-driven.
        fieldItems[.composeSource] = buildFieldItems(includeAutoDetect: true) { [weak self] in self?.applyComposeSource($0) }
        fieldItems[.composeTarget] = buildFieldItems(includeAutoDetect: false) { [weak self] in self?.applyComposeTarget($0) }
        composeCard = MenuCardView(caption: "Compose", shortcut: composeHotkey.display)
        composeCard.onSwap = { [weak self] in
            LanguagePrefs.swapCompose()
            self?.refreshLanguageMenus()
        }
        composeCard.onSourceClicked = { [weak self] in self?.toggle(.composeSource) }
        composeCard.onTargetClicked = { [weak self] in self?.toggle(.composeTarget) }

        fieldItems[.readSource] = buildFieldItems(includeAutoDetect: true) { [weak self] in self?.applyReadSource($0) }
        fieldItems[.readTarget] = buildFieldItems(includeAutoDetect: false) { [weak self] in self?.applyReadTarget($0) }
        readCard = MenuCardView(caption: "Read", shortcut: readHotkey.display)
        readCard.onSwap = { [weak self] in
            LanguagePrefs.swapReadDirection()
            self?.refreshLanguageMenus()
        }
        readCard.onSourceClicked = { [weak self] in self?.toggle(.readSource) }
        readCard.onTargetClicked = { [weak self] in self?.toggle(.readTarget) }

        let settingsRow = FooterRow(title: "⚙ Settings…", hint: "⌘,", width: rowWidth)
        settingsRow.target = self
        settingsRow.action = #selector(openSettings)
        let quitRow = FooterRow(title: "Quit", hint: "⌘Q", width: rowWidth)
        quitRow.target = self
        quitRow.action = #selector(quit)

        menuStack.setRows([
            composeCard,
            readCard,
            SeparatorRow(width: rowWidth),
            buildStatusRow(),
            SeparatorRow(width: rowWidth),
            settingsRow,
            quitRow,
        ])
        dropdown.setContent(menuStack)

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)

        service.onEngineUsed = { [weak self] name in
            self?.lastEngineUsed = name
            self?.reconcileGoogleHealth()
            self?.updateStatusRow()
        }

        // Global hotkeys (defaults ⌥⌘T / ⌥⌘R; changeable in Settings).
        composeHotkey.action = { [weak self] in self?.translateNow() }
        composeHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
        readHotkey.action = { [weak self] in self?.readNow() }
        readHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
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
        // Clear a stale failure so the status light doesn't stay orange after
        // connectivity returns — reconcileGoogleHealth (below) handles the rest.
        if online, lastEngineUsed == "failed" { lastEngineUsed = nil }
        reconcileGoogleHealth()
        updateStatusRow()
    }

    /// Best-effort read on whether Google Translate is currently usable —
    /// combines raw network reachability with the outcome of the last real
    /// translation attempt (reactive: no extra network calls or quota spent
    /// purely for health-checking).
    private var googleHealthy: Bool {
        networkMonitor.isOnline && lastEngineUsed != "apple" && lastEngineUsed != "failed"
    }

    /// Keeps each card's Auto-detect override in sync with Google's health:
    /// substitutes a concrete language when Google breaks (same as before, now
    /// driven by Google's actual health rather than just raw connectivity), and
    /// clears the substitution the moment Google's healthy again — which reverts
    /// to Auto-detect exactly when the standing preference is still "auto" (see
    /// `applyComposeSource`/`applyReadSource`: a pick made *during* an outage
    /// lands there; one made while healthy becomes the new standing preference
    /// instead, and is untouched by this).
    private func reconcileGoogleHealth() {
        if googleHealthy {
            LanguagePrefs.readSourceOverride = nil
            LanguagePrefs.composeSourceOverride = nil
            installedLanguageCodes = nil   // recompute fresh next time we actually rely on Apple
        } else {
            if LanguagePrefs.readSourceCode == Languages.autoCode && LanguagePrefs.readSourceOverride == nil {
                LanguagePrefs.readSourceOverride = LanguagePrefs.lastSpecificReadCode
            }
            if LanguagePrefs.composeSourceCode == Languages.autoCode && LanguagePrefs.composeSourceOverride == nil {
                LanguagePrefs.composeSourceOverride = LanguagePrefs.lastSpecificComposeSourceCode
            }
            if installedLanguageCodes == nil { refreshInstalledLanguageAvailability() }
        }
        refreshLanguageMenus()
    }

    /// Populates `installedLanguageCodes` — async, since checking Apple's
    /// on-device pack status is a real system query, not instant. Until it
    /// resolves, the pickers just show everything unfiltered rather than
    /// waiting; this fills in shortly after, in practice before most users
    /// even open a list.
    private func refreshInstalledLanguageAvailability() {
        guard #available(macOS 15, *) else { installedLanguageCodes = []; return }
        Task { @MainActor in
            var installed: Set<String> = [Languages.englishCode]
            for lang in Languages.all {
                let toEnglish = await AppleLanguagePack.isInstalled(from: lang.code, to: Languages.englishCode)
                let fromEnglish = await AppleLanguagePack.isInstalled(from: Languages.englishCode, to: lang.code)
                if toEnglish || fromEnglish { installed.insert(lang.code) }
            }
            guard !self.googleHealthy else { return }   // recovered while checking — no longer relevant
            self.installedLanguageCodes = installed
        }
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
        service.translateSelectionInPlace()
    }

    private func applyHotkeyRegistration() {
        composeHotkey.register()
        readHotkey.register()
    }

    @objc private func readNow() {
        service.translateSelectionToPopup()
    }

    @objc private func statusItemClicked() {
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

    /// Applies a field's new value and folds its inline list back up — but,
    /// unlike a native menu-item selection, does NOT close the enclosing
    /// status-bar menu (see `LanguageRow`).
    private func applyComposeSource(_ code: String) {
        if googleHealthy {
            // A choice made while everything's working becomes the new standing
            // preference — it survives any future outage and recovery.
            LanguagePrefs.composeSourceCode = code
            LanguagePrefs.composeSourceOverride = nil
        } else {
            // Picked during an outage — treated the same as the automatic
            // substitution: temporary. The standing preference resets to
            // Auto-detect, so it's what this reverts to once Google's healthy.
            LanguagePrefs.composeSourceCode = Languages.autoCode
            LanguagePrefs.composeSourceOverride = code == Languages.autoCode ? nil : code
        }
        if code != Languages.autoCode { LanguagePrefs.lastSpecificComposeSourceCode = code }
        refreshLanguageMenus()
        collapse()
    }

    private func applyComposeTarget(_ code: String) {
        LanguagePrefs.composeTargetCode = code
        refreshLanguageMenus()
        collapse()
    }

    private func applyReadSource(_ code: String) {
        if googleHealthy {
            // A choice made while everything's working becomes the new standing
            // preference — it survives any future outage and recovery.
            LanguagePrefs.readSourceCode = code
            LanguagePrefs.readSourceOverride = nil
        } else {
            // Picked during an outage — treated the same as the automatic
            // substitution: temporary. The standing preference resets to
            // Auto-detect, so it's what this reverts to once Google's healthy.
            LanguagePrefs.readSourceCode = Languages.autoCode
            LanguagePrefs.readSourceOverride = code == Languages.autoCode ? nil : code
        }
        if code != Languages.autoCode { LanguagePrefs.lastSpecificReadCode = code }
        refreshLanguageMenus()
        collapse()
    }

    private func applyReadTarget(_ code: String) {
        LanguagePrefs.readTargetCode = code
        refreshLanguageMenus()
        collapse()
    }

    /// Sync inline-row checkmarks and both direction cards to the current selections.
    private func refreshLanguageMenus() {
        let composeSource = LanguagePrefs.effectiveComposeSourceCode
        let composeTarget = LanguagePrefs.composeTargetCode
        let readSource = LanguagePrefs.effectiveReadSourceCode
        let readTarget = LanguagePrefs.readTargetCode
        checkmark(fieldItems[.composeSource], matching: composeSource)
        checkmark(fieldItems[.composeTarget], matching: composeTarget)
        checkmark(fieldItems[.readSource], matching: readSource)
        checkmark(fieldItems[.readTarget], matching: readTarget)

        composeCard?.shortcut = composeHotkey.display
        readCard?.shortcut = readHotkey.display
        composeCard?.setDirection(left: shortLang(composeSource), right: shortLang(composeTarget))
        readCard?.setDirection(left: shortLang(readSource), right: shortLang(readTarget))
        composeCard?.swapEnabled = composeSource != Languages.autoCode
        readCard?.swapEnabled = readSource != Languages.autoCode
    }

    private func checkmark(_ rows: [LanguageRow]?, matching code: String) {
        for row in rows ?? [] {
            row.isChecked = (row.code == code)
        }
    }

    /// Native display name without the trailing "(English name)" annotation.
    private func shortLang(_ code: String) -> String {
        let full = Languages.name(for: code)
        return String(full.split(separator: " (").first ?? Substring(full))
    }

    /// Builds one field's inline row list. `includeAutoDetect` is true only for
    /// source fields — a target can never be Auto-detect. Each row is a custom
    /// view (`LanguageRow`), not a native menu-item action, so picking one
    /// doesn't dismiss the enclosing panel. Rows don't need to know the panel's
    /// width up front — `VerticalRowStack` resizes every row to fit when it's
    /// actually inserted.
    private func buildFieldItems(includeAutoDetect: Bool, apply: @escaping (String) -> Void) -> [LanguageRow] {
        var codesAndTitles: [(code: String, title: String)] = []
        if includeAutoDetect { codesAndTitles.append((Languages.autoCode, "Auto-detect")) }
        codesAndTitles.append((Languages.englishCode, "English"))
        codesAndTitles += Languages.all.map { ($0.code, $0.name) }

        return codesAndTitles.map { code, title in
            let row = LanguageRow(code: code, title: title)
            row.onSelect = { apply(code) }
            return row
        }
    }

    /// Toggle one field's inline row list. Only one field across both cards is
    /// ever expanded at a time — expanding a new one collapses whatever was open.
    private func toggle(_ field: Field) {
        if expandedField == field { collapse(); return }
        collapse()
        let anchor: MenuCardView = (field == .composeSource || field == .composeTarget) ? composeCard : readCard
        guard let idx = menuStack.rows.firstIndex(of: anchor), let items = fieldItems[field] else { return }
        // Whatever's chosen on the other side of this card can't also be chosen
        // here — translating a language into itself isn't a real option — so
        // leave that one row out. And while relying on Apple (Google down),
        // only offer languages actually installed on-device — Auto-detect
        // included, since Apple can't auto-detect at all — once that's known;
        // if the check hasn't resolved yet, show everything rather than wait.
        let takenByOtherSide = otherSideValue(for: field)
        let visible = items.filter { row in
            guard row.code != takenByOtherSide else { return false }
            guard !googleHealthy, let installed = installedLanguageCodes else { return true }
            return installed.contains(row.code)
        }
        menuStack.insertRows(visible, at: idx + 1)
        expandedField = field
        expandedItems = visible
        updateCardExpansionFlags()
        dropdown.invalidateSize()
    }

    private func collapse() {
        guard !expandedItems.isEmpty else { return }
        menuStack.removeRows(expandedItems)
        expandedItems = []
        expandedField = nil
        updateCardExpansionFlags()
        dropdown.invalidateSize()
    }

    /// The value currently chosen on the opposite side of `field`'s own card,
    /// to exclude from `field`'s own list.
    private func otherSideValue(for field: Field) -> String {
        switch field {
        case .composeSource: return LanguagePrefs.composeTargetCode
        case .composeTarget: return LanguagePrefs.effectiveComposeSourceCode
        case .readSource: return LanguagePrefs.readTargetCode
        case .readTarget: return LanguagePrefs.effectiveReadSourceCode
        }
    }

    private func updateCardExpansionFlags() {
        composeCard?.isExpanded = (expandedField == .composeSource || expandedField == .composeTarget)
        readCard?.isExpanded = (expandedField == .readSource || expandedField == .readTarget)
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


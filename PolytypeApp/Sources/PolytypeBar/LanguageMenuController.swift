import AppKit

/// Owns the Compose and Read direction cards — their language state, each
/// field's inline expandable row list, and applying a picked language back to
/// `LanguagePrefs` — everything that used to live directly on `AppDelegate`
/// for this one part of the menu.
@MainActor
final class LanguageMenuController {
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

    let composeCard: MenuCardView
    let readCard: MenuCardView

    private let menuStack: VerticalRowStack
    private let dropdown: DropdownPanel
    private let composeHotkey: HotkeyController
    private let readHotkey: HotkeyController
    private let health: GoogleHealthMonitor

    init(menuStack: VerticalRowStack, dropdown: DropdownPanel,
         composeHotkey: HotkeyController, readHotkey: HotkeyController, health: GoogleHealthMonitor) {
        self.menuStack = menuStack
        self.dropdown = dropdown
        self.composeHotkey = composeHotkey
        self.readHotkey = readHotkey
        self.health = health

        // Two direction cards, each with an independent source and target
        // field. Both fields on both cards may be Auto-detect on the source
        // side; clicking either field's name expands just that field's list
        // inline below the card. Translation itself is hotkey-driven.
        composeCard = MenuCardView(caption: "Compose", shortcut: composeHotkey.display)
        readCard = MenuCardView(caption: "Read", shortcut: readHotkey.display)

        fieldItems[.composeSource] = buildFieldItems(includeAutoDetect: true) { [weak self] in self?.applyComposeSource($0) }
        fieldItems[.composeTarget] = buildFieldItems(includeAutoDetect: false) { [weak self] in self?.applyComposeTarget($0) }
        composeCard.onSwap = { [weak self] in
            LanguagePrefs.swapCompose()
            self?.refreshLanguageMenus()
        }
        composeCard.onSourceClicked = { [weak self] in self?.toggle(.composeSource) }
        composeCard.onTargetClicked = { [weak self] in self?.toggle(.composeTarget) }

        fieldItems[.readSource] = buildFieldItems(includeAutoDetect: true) { [weak self] in self?.applyReadSource($0) }
        fieldItems[.readTarget] = buildFieldItems(includeAutoDetect: false) { [weak self] in self?.applyReadTarget($0) }
        readCard.onSwap = { [weak self] in
            LanguagePrefs.swapReadDirection()
            self?.refreshLanguageMenus()
        }
        readCard.onSourceClicked = { [weak self] in self?.toggle(.readSource) }
        readCard.onTargetClicked = { [weak self] in self?.toggle(.readTarget) }
    }

    /// Sync inline-row checkmarks and both direction cards to the current selections.
    func refreshLanguageMenus() {
        let composeSource = LanguagePrefs.effectiveComposeSourceCode
        let composeTarget = LanguagePrefs.composeTargetCode
        let readSource = LanguagePrefs.effectiveReadSourceCode
        let readTarget = LanguagePrefs.readTargetCode
        checkmark(fieldItems[.composeSource], matching: composeSource)
        checkmark(fieldItems[.composeTarget], matching: composeTarget)
        checkmark(fieldItems[.readSource], matching: readSource)
        checkmark(fieldItems[.readTarget], matching: readTarget)

        composeCard.shortcut = composeHotkey.display
        readCard.shortcut = readHotkey.display
        composeCard.setDirection(left: shortLang(composeSource), right: shortLang(composeTarget))
        readCard.setDirection(left: shortLang(readSource), right: shortLang(readTarget))
        composeCard.swapEnabled = composeSource != Languages.autoCode
        readCard.swapEnabled = readSource != Languages.autoCode
    }

    /// Folds whichever field is currently expanded back up — called when the
    /// panel is dismissed (so reopening starts fresh) as well as after a pick.
    func collapse(animated: Bool = false) {
        guard !expandedItems.isEmpty else { return }
        menuStack.removeRows(expandedItems, animated: animated)
        expandedItems = []
        expandedField = nil
        updateCardExpansionFlags()
        dropdown.invalidateSize(animated: animated)
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
        // Closing the field that's already open is the "final" transition —
        // worth animating. Closing one to immediately open a different one is
        // an intermediate step, so it collapses instantly and only the new
        // field's insertion (and the resulting resize) animates — avoids a
        // collapse-then-expand double-animation feel.
        if expandedField == field { collapse(animated: true); return }
        collapse(animated: false)
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
            guard !health.isHealthy, let installed = health.installedLanguageCodes else { return true }
            return installed.contains(row.code)
        }
        menuStack.insertRows(visible, at: idx + 1, animated: true)
        expandedField = field
        expandedItems = visible
        updateCardExpansionFlags()
        dropdown.invalidateSize(animated: true)
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
        composeCard.isExpanded = (expandedField == .composeSource || expandedField == .composeTarget)
        readCard.isExpanded = (expandedField == .readSource || expandedField == .readTarget)
    }

    /// Applies a field's new value and folds its inline list back up — but,
    /// unlike a native menu-item selection, does NOT close the enclosing
    /// status-bar menu (see `LanguageRow`).
    private func applyComposeSource(_ code: String) {
        if health.isHealthy {
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
        collapse(animated: true)
    }

    private func applyComposeTarget(_ code: String) {
        LanguagePrefs.composeTargetCode = code
        refreshLanguageMenus()
        collapse(animated: true)
    }

    private func applyReadSource(_ code: String) {
        if health.isHealthy {
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
        collapse(animated: true)
    }

    private func applyReadTarget(_ code: String) {
        LanguagePrefs.readTargetCode = code
        refreshLanguageMenus()
        collapse(animated: true)
    }
}

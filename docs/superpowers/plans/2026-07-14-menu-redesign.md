# Menu Redesign (Direction-First) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the menu-bar dropdown around two direction cards plus a merged status row — 7 rows + 2 separators, down from 13 + 5.

**Architecture:** Two custom `NSView`s (a direction card that draws its own highlight, and a small gradient meter bar) live in a new `MenuViews.swift`. `AppDelegate` composes them into the menu: each card's `NSMenuItem.submenu` is the existing language menu, and one merged `updateStatusRow()` replaces the separate engine/usage updaters. Presentation-only — no translation, hotkey, preview, or metering behavior changes.

**Tech Stack:** Swift 5.9, AppKit (`NSMenu`, view-based `NSMenuItem`, `CALayer`/`CAGradientLayer`). macOS 14 floor.

## Global Constraints

- `swift-tools-version: 5.9`; floor `.macOS(.v14)`; zero compiler warnings; no new dependencies.
- **Presentation only.** Hotkey registration/routing, `translateNow()`/`previewNow()`/`readNow()`, the language submenus and their checkmark logic, preview, and metering must all keep working unchanged.
- Menu width ~292pt.
- The clickable "Translate what I typed" / "Read selection" action rows and the identity header are **deliberately removed** (approved).
- Status-row branches must be evaluated in the spec's exact order — **capped wins over everything** — mirroring the existing `updateEngineStatus()` logic.
- App build: `swift build --package-path TypeTranslatorApp`.

---

### Task 1: MenuViews.swift (direction card + meter bar)

**Files:**
- Create: `TypeTranslatorApp/Sources/TypeTranslatorBar/MenuViews.swift`

**Interfaces:**
- Produces: `final class MenuCardView: NSView` with `init(caption:shortcut:)`, `var direction: String`, `var shortcut: String`; `final class MenuMeterBar: NSView` with `var fraction: CGFloat`, `var isSpent: Bool`.

- [ ] **Step 1: Create the file**

```swift
import AppKit

/// One direction row in the menu-bar dropdown: a caption ("COMPOSE"), the
/// shortcut, a submenu chevron, and the direction ("English → 繁體中文").
///
/// A custom view inside an NSMenuItem does NOT get the system highlight, so this
/// view draws its own from `enclosingMenuItem?.isHighlighted`.
final class MenuCardView: NSView {
    private let captionLabel = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let directionLabel = NSTextField(labelWithString: "")
    private var wasHighlighted = false

    /// The "English → 繁體中文" line.
    var direction: String {
        get { directionLabel.stringValue }
        set { directionLabel.stringValue = newValue }
    }

    /// The displayed shortcut, e.g. "⌥⌘T".
    var shortcut: String {
        get { keyLabel.stringValue }
        set { keyLabel.stringValue = newValue }
    }

    init(caption: String, shortcut: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 48))

        captionLabel.stringValue = caption.uppercased()
        captionLabel.font = .systemFont(ofSize: 10, weight: .bold)
        captionLabel.textColor = .tertiaryLabelColor

        keyLabel.stringValue = shortcut
        keyLabel.font = .systemFont(ofSize: 11.5)
        keyLabel.textColor = .secondaryLabelColor

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor

        directionLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        directionLabel.textColor = .labelColor
        directionLabel.lineBreakMode = .byTruncatingTail

        for v in [captionLabel, keyLabel, directionLabel, chevron] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            captionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: captionLabel.centerYAnchor),
            keyLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            keyLabel.centerYAnchor.constraint(equalTo: captionLabel.centerYAnchor),

            directionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            directionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            directionLabel.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 2),
            directionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Sync label colors before drawing, so `draw(_:)` stays a pure fill.
    override func viewWillDraw() {
        let hi = enclosingMenuItem?.isHighlighted ?? false
        if hi != wasHighlighted {
            wasHighlighted = hi
            captionLabel.textColor = hi ? NSColor.white.withAlphaComponent(0.8) : .tertiaryLabelColor
            keyLabel.textColor = hi ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
            chevron.contentTintColor = hi ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
            directionLabel.textColor = hi ? .white : .labelColor
        }
        super.viewWillDraw()
    }

    override func draw(_ dirtyRect: NSRect) {
        if enclosingMenuItem?.isHighlighted == true {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    // A tracking area makes the highlight redraw reliably as the pointer moves.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
}

/// A thin rounded meter: a track plus a fill whose width is `fraction`. Normally
/// the brand blue→violet gradient; flat gray once the free tier is spent.
final class MenuMeterBar: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CAGradientLayer()

    var fraction: CGFloat = 0 { didSet { needsLayout = true } }
    var isSpent = false { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fillLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fillLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }

    // CALayer colors don't follow appearance changes on their own.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let h = bounds.height
            trackLayer.frame = bounds
            trackLayer.cornerRadius = h / 2
            trackLayer.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor

            let w = max(0, min(1, fraction)) * bounds.width
            fillLayer.frame = CGRect(x: 0, y: 0, width: w, height: h)
            fillLayer.cornerRadius = h / 2
            if isSpent {
                let g = NSColor.systemGray.cgColor
                fillLayer.colors = [g, g]
            } else {
                fillLayer.colors = [
                    NSColor(srgbRed: 74/255, green: 125/255, blue: 1.0, alpha: 1).cgColor,
                    NSColor(srgbRed: 150/255, green: 88/255, blue: 246/255, alpha: 1).cgColor,
                ]
            }
        }
        CATransaction.commit()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -3`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 3: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/MenuViews.swift
git commit -m "feat: direction card and meter bar views for the menu"
```

---

### Task 2: Rebuild the menu in AppDelegate

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift`

**Interfaces:**
- Consumes: `MenuCardView(caption:shortcut:)`, `.direction`, `.shortcut`; `MenuMeterBar.fraction`, `.isSpent` (Task 1).

- [ ] **Step 1: Swap the menu-related stored properties**

Replace these properties:

```swift
    private var engineDotView: NSView!
    private var engineLabel: NSTextField!
    private var lastEngineUsed: String?
    private let networkMonitor = NetworkMonitor()
    private var translateItem: NSMenuItem!
```
```swift
    private var readItem: NSMenuItem!
    private var composeLangMenu: NSMenu!
    private var readLangMenu: NSMenu!
    private var composeStatusLabel: NSTextField!
    private var readStatusLabel: NSTextField!
    private var usageLabel: NSTextField!
    private var usageBar: NSProgressIndicator!
```

with:

```swift
    private var lastEngineUsed: String?
    private let networkMonitor = NetworkMonitor()
    private var composeLangMenu: NSMenu!
    private var readLangMenu: NSMenu!
    private var composeCard: MenuCardView!
    private var readCard: MenuCardView!
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var statusCount: NSTextField!
    private var statusBar: MenuMeterBar!
```

(Keep `statusItem`, `service`, `usageMeter`, `defaultTitle`, and the three hotkey properties exactly as they are.)

- [ ] **Step 2: Replace the whole menu construction**

Replace everything from `let menu = NSMenu()` down to and including `statusItem.menu = menu` with:

```swift
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
```

- [ ] **Step 3: Replace the three view builders with `buildStatusRow()`**

Delete `buildMenuHeader()`, `buildEngineStatusView()`, `buildUsageView()`, and the now-unused `symbol(_:)` helper entirely. Add:

```swift
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
```

- [ ] **Step 4: Merge the two updaters into `updateStatusRow()`**

Delete `updateEngineStatus()` and `updateUsageDisplay()` and add:

```swift
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
```

- [ ] **Step 5: Point every existing caller at the new updater and cards**

`updateEngineStatus()` / `updateUsageDisplay()` are called from several places. Replace **every** call to either with a single `updateStatusRow()` call (in `applicationDidFinishLaunching`, `service.onEngineUsed`, `handleQuotaReached`, `handleNetworkChange`, and `menuWillOpen` — where the two adjacent calls collapse into one).

Then update `refreshLanguageMenus()` — it must no longer touch the deleted item titles/labels, and must update the cards instead:

```swift
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
```

- [ ] **Step 6: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -3`
Expected: `Build complete!`, zero warnings. (If `symbol(_:)` or any deleted label is still referenced, the compiler will point at it — remove the reference.)

- [ ] **Step 7: Manual verify (controller/user)**

Run `./scripts/build-bar.sh && killall TypeTranslatorBar 2>/dev/null; open "build/Type Translator.app"`, then open the 譯 menu:
- Both cards show the right direction and shortcut; hovering fills the card blue with white text and opens its language list; picking a language updates the card text immediately and the checkmark lands correctly.
- Status row: dot/text/count/meter correct; force the capped state (Settings → set usage to 500000) and confirm the full "Free limit reached — on Apple until …" message shows untruncated with a gray full bar, count hidden.
- Footer: Settings… (⌘,), Setup Assistant…, Quit (⌘Q) all work.
- ⌥⌘T / ⌥⌘R / the preview hotkey still translate — removing the action rows must not have broken the actions.
- Check both light and dark mode.

- [ ] **Step 8: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift
git commit -m "feat: direction-first menu with merged status row"
```

---

### Task 3: Update README menu paths

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Fix the two references to rows that no longer exist**

`README.md:67` currently says the target language changes in **譯 → Compose language**, and `README.md:82` says the source language changes in **譯 → Read language**. Those rows are gone — they're cards now. Update both to describe the new interaction, e.g.:

- line ~67: "Change the target language from the **Compose** card in the 譯 menu."
- line ~82: "Change the source language from the **Read** card in the 譯 menu."

(The **譯 → Settings…** and **譯 → Setup Assistant…** references on lines 26, 52 and 60 are still correct — leave them.)

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update menu paths for the redesigned menu"
```

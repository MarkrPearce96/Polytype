# Compose Preview & Back-Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional "preview & confirm" mode to Compose that shows the translation and a back-translation before pasting, so the user can verify a message they can't read before it's inserted.

**Architecture:** A new non-activating floating panel (`ComposePreviewPopup`) presents the forward translation, the back-translation, and Insert/Cancel; it consumes Return/Esc via a short-lived `CGEvent` tap so a confirm keypress never leaks into the chat app. `TranslateService` gains a preview path that forward-translates via the normal engine and back-translates on Apple's free on-device engine. Two UserDefaults toggles + a third registerable hotkey control whether/how preview triggers.

**Tech Stack:** Swift 5.9, AppKit/SwiftUI, Carbon (RegisterEventHotKey), CoreGraphics (CGEvent tap), the existing `TranslationCore` engines. macOS 14 floor; Apple engine gated `@available(macOS 15, *)`.

## Global Constraints

- `swift-tools-version: 5.9`; floor `.macOS(.v14)`; zero compiler warnings.
- Zero new external dependencies.
- **Never-charge guarantee:** the forward translation is the same single call instant already makes (metered via `QuotaGate`); the back-check runs on Apple on-device (zero Google characters); if Apple is unavailable it falls back to the quota-gated engine, which cannot cause a charge; if both fail the popup shows without the "means back" line.
- Default state is **off** — `previewEnabled` defaults `false`, preserving today's instant-replace behavior exactly.
- The preview panel is **non-activating** and never steals focus from the target field.
- While the preview is visible, **Return (36) / keypad Enter (76) / Esc (53) are consumed** and must not reach the app underneath.
- App build: `swift build --package-path TypeTranslatorApp`.

---

### Task 1: Preview prefs + hotkey plumbing

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/Language.swift`
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/HotkeyController.swift`

**Interfaces:**
- Produces: `LanguagePrefs.previewEnabled: Bool`, `LanguagePrefs.previewUsesComposeHotkey: Bool`; `HotkeyController.unregister()`; `HotkeyAccess.preview: HotkeyController?`; `@MainActor enum PreviewControl { static var onSettingsChanged: (() -> Void)? }`.

- [ ] **Step 1: Add the two preview prefs to `LanguagePrefs`**

In `Language.swift`, inside `enum LanguagePrefs`, after the `effectiveReadSourceCode` computed property (before the closing brace), add:

```swift

    /// Whether Compose shows a confirm-before-insert preview. Default off, so the
    /// out-of-box behavior is unchanged (instant replace).
    static var previewEnabled: Bool {
        get { defaults.bool(forKey: "previewEnabled") }
        set { defaults.set(newValue, forKey: "previewEnabled") }
    }

    /// When preview is enabled: true → the Compose hotkey itself shows the preview;
    /// false → a separate preview hotkey does, and Compose stays instant.
    static var previewUsesComposeHotkey: Bool {
        get { defaults.bool(forKey: "previewUsesComposeHotkey") }
        set { defaults.set(newValue, forKey: "previewUsesComposeHotkey") }
    }
```

- [ ] **Step 2: Add `unregister()`, `HotkeyAccess.preview`, and `PreviewControl`**

In `HotkeyController.swift`, add an `unregister()` method to `HotkeyController` (right after the `update(...)` method, before the closing brace of the class):

```swift

    /// Tear down the registered combo (the underlying Carbon hotkey is released in
    /// HotKey's deinit). Used when a toggle turns this hotkey off.
    func unregister() {
        hotKey = nil
    }
```

Then extend `HotkeyAccess` with a `preview` slot and add the `PreviewControl` bridge below it:

```swift
/// Lets the SwiftUI Settings view reach the controllers created in AppDelegate.
@MainActor
enum HotkeyAccess {
    static var compose: HotkeyController?
    static var read: HotkeyController?
    static var preview: HotkeyController?
}

/// Bridge so the SwiftUI Settings view can ask AppDelegate to re-apply hotkey
/// registration after a preview setting changes (no relaunch needed).
@MainActor
enum PreviewControl {
    static var onSettingsChanged: (() -> Void)?
}
```

- [ ] **Step 3: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -3`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 4: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/Language.swift TypeTranslatorApp/Sources/TypeTranslatorBar/HotkeyController.swift
git commit -m "feat: preview prefs, hotkey unregister, and settings bridge"
```

---

### Task 2: ComposePreviewPopup (the confirm panel)

**Files:**
- Create: `TypeTranslatorApp/Sources/TypeTranslatorBar/ComposePreviewPopup.swift`

**Interfaces:**
- Produces: `@MainActor final class ComposePreviewPopup` with `static let shared` and
  `func show(original: String, translation: String, languageName: String, backTranslation: String?, backEngine: String?, at: NSPoint, onInsert: @escaping () -> Void, onCancel: @escaping () -> Void)` and `func dismiss()`.

- [ ] **Step 1: Create the file**

```swift
import AppKit
import CoreGraphics

/// A floating, non-activating panel that previews a Compose translation and its
/// back-translation, letting the user confirm (Return) or cancel (Esc / click /
/// timeout) before anything is pasted. While visible it installs a short-lived
/// CGEvent tap that CONSUMES Return/Enter/Esc so a confirm keypress can't leak
/// into the chat app underneath (e.g. sending a half-finished LINE message).
@MainActor
final class ComposePreviewPopup {
    static let shared = ComposePreviewPopup()

    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var keyMonitorFallback: Any?
    private var dismissTimer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onInsert: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var generation = 0

    func show(original: String, translation: String, languageName: String,
              backTranslation: String?, backEngine: String?,
              at screenPoint: NSPoint,
              onInsert: @escaping () -> Void, onCancel: @escaping () -> Void) {
        teardown()                       // clear any prior panel without firing callbacks
        generation += 1
        let gen = generation
        self.onInsert = onInsert
        self.onCancel = onCancel

        let content = buildContent(original: original, translation: translation,
                                   languageName: languageName,
                                   backTranslation: backTranslation, backEngine: backEngine)
        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let fitting = container.fittingSize
        let size = NSSize(width: max(300, fitting.width), height: max(80, fitting.height))
        let origin = clampedOrigin(for: size, near: screenPoint)

        let newPanel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.hasShadow = true
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hidesOnDeactivate = false
        newPanel.contentView = container
        newPanel.orderFrontRegardless()
        self.panel = newPanel

        installEventTap()

        // Cancel on a click anywhere outside the interaction.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.finish(insert: false)
            }
        }

        // Length-scaled auto-dismiss (= cancel), so a walked-away preview never
        // inserts on its own. Floor 25s, capped 90s.
        let readingTime = min(90, max(25, Double((backTranslation ?? "").count + translation.count) / 8))
        dismissTimer = Timer.scheduledTimer(withTimeInterval: readingTime, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.finish(insert: false)
            }
        }
    }

    func dismiss() { teardown() }

    /// Fire exactly one of the callbacks, then tear everything down.
    fileprivate func finish(insert: Bool) {
        let ins = onInsert, can = onCancel
        onInsert = nil; onCancel = nil
        teardown()
        if insert { ins?() } else { can?() }
    }

    private func teardown() {
        dismissTimer?.invalidate(); dismissTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitorFallback { NSEvent.removeMonitor(keyMonitorFallback) }
        clickMonitor = nil; keyMonitorFallback = nil
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil; eventTap = nil
        panel?.orderOut(nil); panel = nil
        onInsert = nil; onCancel = nil
    }

    // MARK: - Key interception

    /// Install a session-level keyDown tap that consumes Return/Enter/Esc. If the
    /// tap can't be created (should not happen — the app already holds
    /// Accessibility by the time a preview runs), fall back to a non-consuming
    /// global key monitor so the buttons still work.
    private func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: composePreviewTapCallback, userInfo: selfPtr) else {
            installKeyMonitorFallback()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
    }

    private func installKeyMonitorFallback() {
        let gen = generation
        keyMonitorFallback = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                switch event.keyCode {
                case 36, 76: self.finish(insert: true)
                case 53:     self.finish(insert: false)
                default:     break
                }
            }
        }
    }

    // MARK: - Layout

    private func buildContent(original: String, translation: String, languageName: String,
                              backTranslation: String?, backEngine: String?) -> NSView {
        func section(_ caption: String, _ value: String, emphasized: Bool) -> NSStackView {
            let cap = NSTextField(labelWithString: caption.uppercased())
            cap.font = .systemFont(ofSize: 10, weight: .semibold)
            cap.textColor = .tertiaryLabelColor
            let val = NSTextField(wrappingLabelWithString: value)
            val.font = emphasized ? .systemFont(ofSize: 16, weight: .semibold) : .systemFont(ofSize: 13)
            val.textColor = .labelColor
            val.isSelectable = true
            val.preferredMaxLayoutWidth = 340
            let s = NSStackView(views: [cap, val])
            s.orientation = .vertical; s.alignment = .leading; s.spacing = 2
            return s
        }

        var rows: [NSView] = [
            section("You typed", original, emphasized: false),
            section("Will send · \(languageName)", translation, emphasized: true),
        ]
        if let back = backTranslation, !back.isEmpty {
            let label = "Means back" + (backEngine.map { " · \($0)" } ?? "")
            rows.append(section(label, back, emphasized: false))
        }
        let sep = NSBox(); sep.boxType = .separator
        rows.append(sep)
        let hint = NSTextField(labelWithString: "⏎ Insert      esc Cancel")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        rows.append(hint)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        // Make the separator span the content width.
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        return stack
    }

    private func clampedOrigin(for size: NSSize, near point: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = point.x + 12
        var y = point.y - size.height - 12
        x = min(max(frame.minX, x), frame.maxX - size.width)
        y = min(max(frame.minY, y), frame.maxY - size.height)
        return NSPoint(x: x, y: y)
    }
}

/// C-callback for the preview key tap. Runs on the main run loop (the source is
/// added to `CFRunLoopGetMain`), so main-actor access is safe. Consumes
/// Return/Enter/Esc (returns nil); passes everything else through.
private func composePreviewTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                                       event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let popup = Unmanaged<ComposePreviewPopup>.fromOpaque(refcon).takeUnretainedValue()

    // The system disables a tap that times out or is interrupted; re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { popup.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch code {
        case 36, 76:   // Return / keypad Enter
            MainActor.assumeIsolated { popup.finish(insert: true) }
            return nil
        case 53:       // Esc
            MainActor.assumeIsolated { popup.finish(insert: false) }
            return nil
        default:
            break
        }
    }
    return Unmanaged.passUnretained(event)
}

extension ComposePreviewPopup {
    /// Re-enable the tap after the system disabled it (called from the callback).
    fileprivate func reenableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -3`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 3: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/ComposePreviewPopup.swift
git commit -m "feat: ComposePreviewPopup confirm panel with key-consuming event tap"
```

---

### Task 3: TranslateService preview flow

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/TranslateService.swift`

**Interfaces:**
- Consumes: `ComposePreviewPopup.shared.show(...)` (Task 2); `LanguagePrefs.composeTargetCode`; `Languages.name(for:)`.
- Produces: `TranslateService.init(engine:fallbackFlag:backTranslateEngine:)` and `func translateSelectionWithPreview()`.

- [ ] **Step 1: Add the back-translate engine to `init`**

In `TranslateService.swift`, add a stored property and extend `init`. Replace the existing property block and initializer:

```swift
    private let engine: TranslationEngine
    private let backTranslateEngine: TranslationEngine?
    private let fallbackFlag: FallbackFlag
    private var busy = false
    private var opToken = 0
```

```swift
    init(engine: TranslationEngine, fallbackFlag: FallbackFlag = FallbackFlag(),
         backTranslateEngine: TranslationEngine? = nil) {
        self.engine = engine
        self.fallbackFlag = fallbackFlag
        self.backTranslateEngine = backTranslateEngine
    }
```

- [ ] **Step 2: Add the preview flow methods**

In `TranslateService.swift`, immediately after `translateSelectionInPlace()` (before `translateClipboard`), add:

```swift
    /// Like `translateSelectionInPlace`, but instead of pasting immediately it
    /// shows a confirm-before-insert preview with a back-translation.
    func translateSelectionWithPreview() {
        guard !busy else { return }
        guard ensureAccessibility() else {
            onStatus?("⚠")
            promptAccessibility()
            return
        }
        busy = true
        onStatus?("…")
        armWatchdog()

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let cursor = NSEvent.mouseLocation
        let before = pb.changeCount
        postCommandKey(CGKeyCode(kVK_ANSI_C))
        waitForClipboardChange(pb, from: before, attempts: 12) { [weak self] hadSelection in
            guard let self else { return }
            if hadSelection {
                self.previewClipboard(pb: pb, saved: saved, at: cursor)
            } else {
                let before2 = pb.changeCount
                self.postCommandKey(CGKeyCode(kVK_ANSI_A))
                self.postCommandKey(CGKeyCode(kVK_ANSI_C))
                self.waitForClipboardChange(pb, from: before2, attempts: 25) { changed in
                    if changed {
                        self.previewClipboard(pb: pb, saved: saved, at: cursor)
                    } else {
                        self.finish(status: "∅", restore: saved, to: pb, after: 0.1)
                    }
                }
            }
        }
    }

    /// Forward-translate the clipboard English, back-translate for reassurance,
    /// then show the preview. Paste only happens on confirm.
    private func previewClipboard(pb: NSPasteboard, saved: String?, at cursor: NSPoint) {
        let english = pb.string(forType: .string) ?? ""
        guard !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finish(status: "∅", restore: saved, to: pb, after: 0.1)
            return
        }
        let target = LanguagePrefs.composeTargetCode
        Task { @MainActor in
            do {
                self.fallbackFlag.value = false
                let translated = try await self.engine.translate(english, from: "en", to: target)
                guard !translated.isEmpty else {
                    self.finish(status: "∅", restore: saved, to: pb, after: 0.1)
                    return
                }
                let forwardEngine = self.fallbackFlag.value ? "apple" : "google"
                let (back, backEngineName) = await self.backTranslate(translated, from: target)
                let fullName = Languages.name(for: target)
                let shortName = String(fullName.split(separator: " (").first ?? Substring(fullName))
                ComposePreviewPopup.shared.show(
                    original: english, translation: translated, languageName: shortName,
                    backTranslation: back, backEngine: backEngineName, at: cursor,
                    onInsert: { [weak self] in
                        guard let self else { return }
                        pb.clearContents()
                        pb.setString(translated, forType: .string)
                        self.postCommandKey(CGKeyCode(kVK_ANSI_V))
                        self.onEngineUsed?(forwardEngine)
                        self.finish(status: "✓", restore: saved, to: pb, after: 0.4)
                    },
                    onCancel: { [weak self] in
                        self?.finish(status: "", restore: saved, to: pb, after: 0.1)
                    })
            } catch {
                self.onEngineUsed?("failed")
                self.finish(status: "⚠", restore: saved, to: pb, after: 0.1)
            }
        }
    }

    /// Back-translation for the preview's reassurance line. Apple on-device first
    /// (zero Google quota); else the quota-gated engine (still never charges);
    /// else nil (popup omits the "means back" line). Returns (text, engineLabel).
    private func backTranslate(_ text: String, from source: String) async -> (String?, String?) {
        if let apple = backTranslateEngine,
           let r = try? await apple.translate(text, from: source, to: "en"), !r.isEmpty {
            return (r, "Apple")
        }
        if let r = try? await engine.translate(text, from: source, to: "en"), !r.isEmpty {
            return (r, "Google")
        }
        return (nil, nil)
    }
```

- [ ] **Step 3: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -3`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 4: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/TranslateService.swift
git commit -m "feat: preview translation flow with Apple-first back-translation"
```

---

### Task 4: AppDelegate wiring

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift`

**Interfaces:**
- Consumes: `TranslateService(engine:fallbackFlag:backTranslateEngine:)` (Task 3); `HotkeyAccess.preview`, `PreviewControl.onSettingsChanged`, `HotkeyController.unregister()`, `LanguagePrefs.previewEnabled/previewUsesComposeHotkey` (Task 1); `service.translateSelectionWithPreview()` (Task 3).

- [ ] **Step 1: Add a stored property for the preview hotkey**

In `AppDelegate.swift`, after `private var readHotkey: HotkeyController!` (line ~18), add:

```swift
    private var previewHotkey: HotkeyController!
```

- [ ] **Step 2: Build the back-translate engine and pass it to the service**

Replace the service construction line:

```swift
        service = TranslateService(engine: engine, fallbackFlag: flag)
```

with:

```swift
        var backEngine: TranslationEngine? = nil
        if #available(macOS 15, *) { backEngine = AppleEngine() }
        service = TranslateService(engine: engine, fallbackFlag: flag, backTranslateEngine: backEngine)
```

- [ ] **Step 3: Create and expose the preview hotkey**

After the `HotkeyAccess.read = readHotkey` line, add:

```swift
        previewHotkey = HotkeyController(id: "preview",
            defaultKeyCode: UInt32(kVK_ANSI_T),
            defaultModifiers: UInt32(cmdKey | optionKey | shiftKey), defaultDisplay: "⌥⇧⌘T")
        HotkeyAccess.preview = previewHotkey
```

- [ ] **Step 4: Wire actions, registration, and the settings bridge**

Replace the whole hotkey-wiring block:

```swift
        // Global hotkeys (defaults ⌥⌘T / ⌥⌘R; changeable in Settings).
        composeHotkey.action = { [weak self] in self?.translateNow() }
        composeHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
        composeHotkey.register()

        readHotkey.action = { [weak self] in self?.readNow() }
        readHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
        readHotkey.register()
```

with:

```swift
        // Global hotkeys (defaults ⌥⌘T / ⌥⌘R / ⌥⇧⌘T; changeable in Settings).
        composeHotkey.action = { [weak self] in self?.translateNow() }
        composeHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
        readHotkey.action = { [weak self] in self?.readNow() }
        readHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
        previewHotkey.action = { [weak self] in self?.previewNow() }
        previewHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
        PreviewControl.onSettingsChanged = { [weak self] in self?.applyHotkeyRegistration() }
        applyHotkeyRegistration()
```

- [ ] **Step 5: Add the routing + registration helpers**

Replace the existing `translateNow` action:

```swift
    @objc private func translateNow() {
        service.translateSelectionInPlace()
    }
```

with:

```swift
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
```

- [ ] **Step 6: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -3`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 7: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift
git commit -m "feat: wire preview hotkey, routing, and back-translate engine"
```

---

### Task 5: Settings Preview section

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/SettingsWindow.swift`

**Interfaces:**
- Consumes: `LanguagePrefs.previewEnabled/previewUsesComposeHotkey`, `HotkeyAccess.preview`, `PreviewControl.onSettingsChanged` (Task 1).

- [ ] **Step 1: Add preview `@State` to `SettingsView`**

In `SettingsWindow.swift`, after `@State private var launchAtLogin: Bool = LoginItem.isEnabled`, add:

```swift
    @State private var previewEnabled: Bool = false                       // seeded in .onAppear
    @State private var previewUsesComposeHotkey: Bool = false             // seeded in .onAppear
    @State private var previewDisplay: String = "⌥⇧⌘T"                    // seeded in .onAppear
```

- [ ] **Step 2: Add the Preview section to the Form**

Insert a new section immediately after the `Section("Translation") { ... }` block and before `Section("Usage")`:

```swift
                Section("Preview") {
                    Toggle("Preview before inserting", isOn: $previewEnabled)
                        .onChange(of: previewEnabled) { _, on in
                            LanguagePrefs.previewEnabled = on
                            PreviewControl.onSettingsChanged?()
                            status = on ? "Preview on — Compose will show a confirm step."
                                        : "Preview off — Compose inserts instantly."
                        }
                    if previewEnabled {
                        Picker("Trigger", selection: $previewUsesComposeHotkey) {
                            Text("Separate hotkey").tag(false)
                            Text("Use my Compose hotkey").tag(true)
                        }
                        .onChange(of: previewUsesComposeHotkey) { _, useCompose in
                            LanguagePrefs.previewUsesComposeHotkey = useCompose
                            PreviewControl.onSettingsChanged?()
                        }
                        if !previewUsesComposeHotkey {
                            LabeledContent("Preview shortcut") {
                                HotkeyRecorder(current: previewDisplay) { keyCode, mods, display in
                                    if HotkeyAccess.preview?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
                                        previewDisplay = display; status = "Preview shortcut set to \(display)."
                                    } else { status = "That shortcut is already in use — try another." }
                                }.frame(width: 132, height: 24)
                            }
                        }
                        caption("Shows the translation and what it means back in English before inserting. Return inserts; Esc cancels. The back-check uses Apple's free on-device engine, so it doesn't count against your Google free tier.")
                    }
                }
```

- [ ] **Step 3: Seed the preview state in `.onAppear`**

In the existing `.onAppear` block (currently seeding `key`, `renewDate`, `usageInput`), add:

```swift
            previewEnabled = LanguagePrefs.previewEnabled
            previewUsesComposeHotkey = LanguagePrefs.previewUsesComposeHotkey
            previewDisplay = HotkeyAccess.preview?.display ?? "⌥⇧⌘T"
```

- [ ] **Step 4: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -3`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 5: Manual verify (controller/user)**

Build the bundle and run: `./scripts/build-bar.sh && killall TypeTranslatorBar 2>/dev/null; open "build/Type Translator.app"`. Then in a text field (e.g. Notes or LINE):
- **Preview off:** ⌥⌘T still instant-replaces (unchanged).
- **Preview on + Separate hotkey:** ⌥⌘T instant; ⌥⇧⌘T shows the preview (You typed / Will send / Means back · Apple). Return inserts in place; Esc cancels leaving the text untouched.
- **Preview on + Use my Compose hotkey:** ⌥⌘T now shows the preview; the separate shortcut recorder is hidden.
- Toggling any of these takes effect without relaunching.
- Pressing Return/Esc over the preview does NOT add a newline or send in the chat app.
- The usage meter rises only by the forward text's length (the Apple back-check adds nothing); the "Means back" line reads "Apple".

- [ ] **Step 6: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/SettingsWindow.swift
git commit -m "feat: Settings Preview section (toggles + preview shortcut)"
```

---

### Task 6: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document preview mode**

In `README.md`, in the Usage section (near the Compose bullet), add a bullet:

> - **Preview before sending (optional):** turn on **Settings → Preview → "Preview before inserting"** to see the translation *and what it means back in English* before it's inserted — press **Return** to insert, **Esc** to cancel. Choose whether it runs on a separate shortcut (default ⌥⇧⌘T) or takes over your Compose shortcut. The back-check uses Apple's free on-device engine, so it never counts against your Google free tier.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document Compose preview mode"
```

# Reverse (Read) Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only Taiwanese-Mandarin → English direction on a second, customizable global hotkey that shows the translation in a popup near the cursor, without disturbing the existing English → Mandarin compose flow.

**Architecture:** Generalize the `TranslationEngine` protocol to carry a source language so any direction works; add a second named global hotkey; add a floating `ResultPopup` panel; add a read path to `TranslateService` that copies the selection, translates zh-TW → English, and shows the popup.

**Tech Stack:** Swift 5.9 (Swift 5 language mode), AppKit, Carbon (hotkeys), SwiftPM, XCTest. macOS 14 platform floor; Apple Translation APIs gated to macOS 15+.

## Global Constraints

- `swift-tools-version: 5.9`; platform floor `.macOS(.v14)`. Any macOS-15-only API gated with `@available(macOS 15.0, *)`.
- All engines remain `Sendable` (or `@unchecked Sendable` with lock-protected state).
- Zero compiler warnings on a clean build.
- Target language codes: English `en`, Taiwanese Mandarin `zh-TW`. Google maps any `zh*` to `zh-TW`.
- Menu-bar app is `LSUIElement`; signing via `scripts/build-bar.sh` (Apple Development identity).
- Build the core: `swift test --package-path TranslationCore`. Build the app: `swift build --package-path TypeTranslatorApp`.

---

### Task 1: Generalize the engine protocol to carry a source language

**Files:**
- Modify: `TranslationCore/Sources/TranslationCore/TranslationEngine.swift`
- Modify: `TranslationCore/Sources/TranslationCore/GoogleEngine.swift`
- Modify: `TranslationCore/Sources/TranslationCore/DeepLEngine.swift`
- Modify: `TranslationCore/Sources/TranslationCore/AppleEngine.swift`
- Modify: `TranslationCore/Sources/TranslationCore/FallbackChain.swift`
- Modify tests: `TranslationCore/Tests/TranslationCoreTests/GoogleEngineTests.swift`, `DeepLEngineTests.swift`, `FallbackChainTests.swift`
- Modify call site: `TypeTranslatorApp/Sources/TypeTranslatorBar/TranslateService.swift`

**Interfaces:**
- Produces: `TranslationEngine.translate(_ text: String, from source: String, to target: String) async throws -> String` — the new protocol method every engine implements and every caller uses.

- [ ] **Step 1: Update the reverse-direction Google test first (will fail to compile)**

In `GoogleEngineTests.swift`, add:

```swift
func testReverseDirectionRequest() async throws {
    let http = MockHTTP(.success(HTTPResponse(status: 200, body: okBody("how are you"))))
    let engine = GoogleEngine(secrets: secrets("k"), http: http)
    _ = try await engine.translate("你好嗎", from: "zh-TW", to: "en")
    XCTAssertEqual(http.lastForm["source"], "zh-TW")
    XCTAssertEqual(http.lastForm["target"], "en")
    XCTAssertEqual(http.lastForm["q"], "你好嗎")
}
```

- [ ] **Step 2: Run tests to confirm the whole suite fails to compile**

Run: `swift test --package-path TranslationCore 2>&1 | tail -5`
Expected: compile error — extra argument `from:` / signature mismatch.

- [ ] **Step 3: Change the protocol signature**

In `TranslationEngine.swift`, replace the method:

```swift
public protocol TranslationEngine: Sendable {
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}
```

- [ ] **Step 4: Update GoogleEngine**

In `GoogleEngine.swift`, replace `googleTarget` with a shared mapper and update `translate`:

```swift
/// Google's language codes: any Chinese variant → Traditional (Taiwan); others pass through.
private func googleLang(_ code: String) -> String {
    code.lowercased().hasPrefix("zh") ? "zh-TW" : code
}

public func translate(_ text: String, from source: String, to target: String) async throws -> String {
    guard let key = secrets.get(googleKeyName), !key.isEmpty else { throw TranslationError.noAPIKey }
    let url = URL(string: "https://\(host)/language/translate/v2")!
    let form = [
        "q": text,
        "source": googleLang(source),
        "target": googleLang(target),
        "format": "text",
        "key": key,
    ]
    // ... unchanged from here down (post, status switch, decode, unescapeHTML) ...
```

Keep the rest of the method body (the `http.post`, status `switch`, `Payload` decode, and `return Self.unescapeHTML(text)`) exactly as-is, only renaming the decoded variable if it collides with the `text` parameter (rename the returned decode variable to `translated`):

```swift
    guard let payload = try? JSONDecoder().decode(Payload.self, from: resp.body),
          let translated = payload.data.translations.first?.translatedText, !translated.isEmpty else {
        throw TranslationError.empty
    }
    return Self.unescapeHTML(translated)
}
```

- [ ] **Step 5: Update DeepLEngine**

In `DeepLEngine.swift`, add a source mapper and update `translate`:

```swift
private func deepLSource(_ code: String) -> String {
    code.lowercased().hasPrefix("zh") ? "ZH" : code.uppercased()
}

public func translate(_ text: String, from source: String, to target: String) async throws -> String {
    guard let key = secrets.get(deepLKeyName), !key.isEmpty else { throw TranslationError.noAPIKey }
    let url = URL(string: "https://\(host)/v2/translate")!
    let headers = ["Authorization": "DeepL-Auth-Key \(key)"]
    let form = ["text": text, "source_lang": deepLSource(source), "target_lang": deepLTarget(target)]
    // ... rest of the method unchanged ...
```

- [ ] **Step 6: Update AppleEngine (both the real and stub implementations)**

In `AppleEngine.swift`, in the `#if canImport(Translation)` implementation, change `translate` to use the source:

```swift
public func translate(_ text: String, from source: String, to target: String) async throws -> String {
    let config = TranslationSession.Configuration(
        source: Locale.Language(identifier: source),
        target: Locale.Language(identifier: target)
    )
    do {
        let session = try await SessionProvider.session(for: config)
        let targetText = try await withTimeout(
            seconds: SessionProvider.sessionTimeout,
            onTimeout: { TranslationError.network("apple: translate timeout") }
        ) {
            try await session.translate(text).targetText
        }
        guard !targetText.isEmpty else { throw TranslationError.empty }
        return targetText
    } catch let e as TranslationError {
        throw e
    } catch {
        throw TranslationError.network("apple: \(error)")
    }
}
```

And in the `#else` stub:

```swift
public func translate(_ text: String, from source: String, to target: String) async throws -> String {
    throw TranslationError.network("Translation framework unavailable")
}
```

- [ ] **Step 7: Update FallbackChain**

In `FallbackChain.swift`, update `translate` to pass source/target through:

```swift
public func translate(_ text: String, from source: String, to target: String) async throws -> String {
    do { return try await primary.translate(text, from: source, to: target) }
    catch let error as TranslationError {
        onFallback?(error)
        return try await fallback.translate(text, from: source, to: target)
    }
}
```

- [ ] **Step 8: Update existing engine tests to the new signature**

In `GoogleEngineTests.swift` and `DeepLEngineTests.swift`, replace every call of the form `engine.translate("hi", to: "zh-TW")` with `engine.translate("hi", from: "en", to: "zh-TW")`. In `GoogleEngineTests.testSendsCorrectRequest`, add `XCTAssertEqual(http.lastForm["source"], "en")`. In `DeepLEngineTests.testSendsCorrectRequest`, add `XCTAssertEqual(http.lastForm["source_lang"], "EN")`.

- [ ] **Step 9: Update FallbackChain tests**

In `FallbackChainTests.swift`, update every fake engine's `translate` method and every direct call to the 3-argument signature `translate(_ text: String, from source: String, to target: String)`. Add one assertion in an existing success test that the source/target reach the primary (e.g. capture `lastSource`/`lastTarget` in the fake and assert `"en"`/`"zh-TW"`).

- [ ] **Step 10: Update the compose call site in the app**

In `TranslateService.swift`, find the call `try await self.engine.translate(english, to: self.target)` and replace with:

```swift
let mandarin = try await self.engine.translate(english, from: "en", to: self.target)
```

(`self.target` stays `"zh-TW"`.)

- [ ] **Step 11: Run all core tests + build the app**

Run: `swift test --package-path TranslationCore 2>&1 | grep -E "Executed [0-9]+ tests|error:"`
Expected: `Executed 36 tests, with 0 failures` (35 existing + 1 new reverse test).
Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1`
Expected: `Build complete!`

- [ ] **Step 12: Commit**

```bash
git add TranslationCore TypeTranslatorApp/Sources/TypeTranslatorBar/TranslateService.swift
git commit -m "feat: engines translate any direction (add source language param)"
```

---

### Task 2: ResultPopup — floating panel that shows text near the cursor

**Files:**
- Create: `TypeTranslatorApp/Sources/TypeTranslatorBar/ResultPopup.swift`

**Interfaces:**
- Produces: `@MainActor final class ResultPopup` with `static let shared: ResultPopup`, `func show(_ text: String, at screenPoint: NSPoint)`, and `func dismiss()`. `show` replaces any existing popup; the panel dismisses on Esc, click, focus loss, or an ~8s timeout.

- [ ] **Step 1: Create the ResultPopup**

Create `ResultPopup.swift`:

```swift
import AppKit

/// A small, non-activating floating panel that shows a line of text near a
/// screen point (e.g. the mouse). Used to display read-mode translations
/// without stealing focus or altering any document.
@MainActor
final class ResultPopup {
    static let shared = ResultPopup()

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    func show(_ text: String, at screenPoint: NSPoint) {
        dismiss()

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 360

        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        let fitting = container.fittingSize
        let size = NSSize(width: max(120, fitting.width), height: max(40, fitting.height))
        let origin = clampedOrigin(for: size, near: screenPoint)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.contentView = container
        panel.orderFrontRegardless()
        self.panel = panel

        // Dismiss on a click anywhere.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        // Dismiss on Esc (global monitor, since the panel is non-activating and
        // never becomes key). Requires Accessibility, which the app already has.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.dismiss() } }   // 53 = Escape
        }
        // Auto-dismiss fallback.
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate(); dismissTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Keep the panel fully on the screen that contains `point`.
    private func clampedOrigin(for size: NSSize, near point: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Offset slightly below-right of the cursor.
        var x = point.x + 12
        var y = point.y - size.height - 12
        x = min(max(frame.minX, x), frame.maxX - size.width)
        y = min(max(frame.minY, y), frame.maxY - size.height)
        return NSPoint(x: x, y: y)
    }
}
```

- [ ] **Step 2: Build the app**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1`
Expected: `Build complete!`

- [ ] **Step 3: Manually verify the popup renders**

Temporarily add, at the end of `AppDelegate.applicationDidFinishLaunching`:

```swift
ResultPopup.shared.show("Popup test — 你好嗎 → How are you?", at: NSEvent.mouseLocation)
```

Run `./scripts/build-bar.sh && open "build/Type Translator.app"`. Expected: a rounded popup appears near the pointer, dismisses on click/Esc/after 8s. Then **remove** the temporary line.

- [ ] **Step 4: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/ResultPopup.swift
git commit -m "feat: ResultPopup floating panel for read-mode translations"
```

---

### Task 3: Two named, customizable hotkeys

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/HotkeyController.swift`
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift`

**Interfaces:**
- Produces: `HotkeyController` becomes instance-based: `init(id: String, defaultKeyCode: UInt32, defaultModifiers: UInt32, defaultDisplay: String)`, with per-instance `display`, `action`, `onChange`, `register()`, and `update(keyCode:carbonMods:display:)`. Persistence keys are namespaced by `id`.

- [ ] **Step 1: Convert HotkeyController from singleton to instance**

Replace the top of `HotkeyController.swift` (the `static let shared`, `Key` enum, stored props, and `init`) with:

```swift
@MainActor
final class HotkeyController {
    private let id: String
    private var keyCode: UInt32
    private var carbonMods: UInt32
    private(set) var display: String
    private var hotKey: HotKey?

    var action: (() -> Void)?
    var onChange: ((String) -> Void)?

    init(id: String, defaultKeyCode: UInt32, defaultModifiers: UInt32, defaultDisplay: String) {
        self.id = id
        let d = UserDefaults.standard
        keyCode = UInt32(d.object(forKey: "hotkey.\(id).keyCode") as? Int ?? Int(defaultKeyCode))
        carbonMods = UInt32(d.object(forKey: "hotkey.\(id).modifiers") as? Int ?? Int(defaultModifiers))
        display = d.string(forKey: "hotkey.\(id).display") ?? defaultDisplay
    }
```

Keep `register()` unchanged. In `update(...)`, change the three `UserDefaults` keys to the namespaced form:

```swift
d.set(Int(newKey), forKey: "hotkey.\(id).keyCode")
d.set(Int(newMods), forKey: "hotkey.\(id).modifiers")
d.set(newDisplay, forKey: "hotkey.\(id).display")
```

- [ ] **Step 2: Create both controllers BEFORE the menu, add properties + import**

In `AppDelegate.swift`, add `import Carbon` back at the top (needed for `kVK_ANSI_T`, `kVK_ANSI_R`, `cmdKey`, `optionKey`). Add stored properties near the top of the class:

```swift
private var composeHotkey: HotkeyController!
private var readHotkey: HotkeyController!
private var readItem: NSMenuItem!
```

Ordering matters: the menu items display each hotkey's current combo, so **create both controllers before building the menu**. In `applicationDidFinishLaunching`, immediately after `service = TranslateService(...)` and before the `statusItem`/menu setup, insert:

```swift
composeHotkey = HotkeyController(id: "compose",
    defaultKeyCode: UInt32(kVK_ANSI_T), defaultModifiers: UInt32(cmdKey | optionKey), defaultDisplay: "⌥⌘T")
readHotkey = HotkeyController(id: "read",
    defaultKeyCode: UInt32(kVK_ANSI_R), defaultModifiers: UInt32(cmdKey | optionKey), defaultDisplay: "⌥⌘R")
```

- [ ] **Step 3: Build the menu with both items, then wire actions**

In the menu construction, change `translateItem`'s title to use `composeHotkey.display`, and add the read item right after it:

```swift
translateItem = NSMenuItem(title: "Translate what I typed  (\(composeHotkey.display))",
                           action: #selector(translateNow), keyEquivalent: "")
menu.addItem(translateItem)
readItem = NSMenuItem(title: "Translate selection to English  (\(readHotkey.display))",
                      action: #selector(readNow), keyEquivalent: "")
menu.addItem(readItem)
```

Then delete the old `HotkeyController.shared` block and, after the menu is assigned to `statusItem`, wire actions/onChange/register for both:

```swift
composeHotkey.action = { [weak self] in self?.translateNow() }
composeHotkey.onChange = { [weak self] d in self?.translateItem.title = "Translate what I typed  (\(d))" }
composeHotkey.register()

readHotkey.action = { [weak self] in self?.readNow() }
readHotkey.onChange = { [weak self] d in self?.readItem.title = "Translate selection to English  (\(d))" }
readHotkey.register()
```

Add a temporary stub method (replaced in Task 4):

```swift
@objc private func readNow() {
    ResultPopup.shared.show("Read hotkey works", at: NSEvent.mouseLocation)
}
```

- [ ] **Step 4: Build and manually verify both hotkeys register**

Run: `./scripts/build-bar.sh && killall TypeTranslatorBar 2>/dev/null; open "build/Type Translator.app"`
Expected: compose still translates in place; pressing ⌥⌘R shows the "Read hotkey works" popup near the cursor. The menu lists both shortcuts.

- [ ] **Step 5: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/HotkeyController.swift TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift
git commit -m "feat: two named customizable hotkeys (compose + read)"
```

---

### Task 4: Read path in TranslateService

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/TranslateService.swift`
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift`

**Interfaces:**
- Consumes: `ResultPopup.shared.show(_:at:)`, `engine.translate(_:from:to:)`.
- Produces: `TranslateService.translateSelectionToPopup()` — copies the current selection, translates zh-TW → English, shows the result in `ResultPopup` near the mouse; beeps and shows nothing if no selection.

- [ ] **Step 1: Add the read path to TranslateService**

In `TranslateService.swift`, add this method (reuses existing `ensureAccessibility`, `postCommandKey`, `waitForClipboardChange`, `armWatchdog`, `busy`, `opToken`, and the `finish`-style clipboard restore):

```swift
/// Read mode: translate the current selection zh-TW → English and show it in a
/// popup near the cursor. Never pastes; restores the clipboard.
func translateSelectionToPopup() {
    guard !busy else { return }
    guard ensureAccessibility() else { onStatus?("⚠"); promptAccessibility(); return }
    busy = true
    onStatus?("…")
    armWatchdog()

    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    let cursor = NSEvent.mouseLocation
    let before = pb.changeCount
    postCommandKey(CGKeyCode(kVK_ANSI_C))   // copy selection only (no select-all)

    waitForClipboardChange(pb, from: before, attempts: 12) { [weak self] hadSelection in
        guard let self else { return }
        guard hadSelection else {
            NSSound.beep()
            self.finishRead(status: "∅", restore: saved, to: pb)
            return
        }
        let chinese = pb.string(forType: .string) ?? ""
        guard !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            self.finishRead(status: "∅", restore: saved, to: pb)
            return
        }
        Task { @MainActor in
            do {
                let english = try await self.engine.translate(chinese, from: "zh-TW", to: "en")
                ResultPopup.shared.show(english.isEmpty ? "(no translation)" : english, at: cursor)
                self.finishRead(status: "✓", restore: saved, to: pb)
            } catch {
                ResultPopup.shared.show("Couldn't translate — check connection or API key.", at: cursor)
                self.finishRead(status: "⚠", restore: saved, to: pb)
            }
        }
    }
}

/// Read mode never pastes, so restore the clipboard immediately.
private func finishRead(status: String, restore saved: String?, to pb: NSPasteboard) {
    onStatus?(status)
    pb.clearContents()
    if let saved { pb.setString(saved, forType: .string) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
        self?.busy = false
        self?.onStatus?("")
    }
}
```

- [ ] **Step 2: Replace the readNow stub in AppDelegate**

In `AppDelegate.swift`, replace the temporary `readNow` body with:

```swift
@objc private func readNow() {
    service.translateSelectionToPopup()
}
```

- [ ] **Step 3: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1`
Expected: `Build complete!`

- [ ] **Step 4: Manually verify read translation end-to-end**

Run: `./scripts/build-bar.sh && killall TypeTranslatorBar 2>/dev/null; open "build/Type Translator.app"`.
- In TextEdit, type `你好嗎`, select it, press ⌥⌘R → popup shows "How are you?" (or similar); the text is NOT changed; menu shows "Last translation: Google".
- Select nothing, press ⌥⌘R → a beep, no popup.
- Confirm your clipboard is unchanged after a read.

- [ ] **Step 5: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/TranslateService.swift TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift
git commit -m "feat: read-mode translate-to-popup (zh-TW to English)"
```

---

### Task 5: Read-shortcut recorder in Settings

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/SettingsWindow.swift`
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift`

**Interfaces:**
- Consumes: the `readHotkey: HotkeyController` created in `AppDelegate`.
- Produces: a second `HotkeyRecorder` row in Settings bound to the read hotkey.

- [ ] **Step 1: Expose the hotkey controllers to Settings**

The Settings view is constructed independently of `AppDelegate`, so expose the two controllers through a small shared holder. In `AppDelegate.swift`, after creating both controllers, assign:

```swift
HotkeyAccess.compose = composeHotkey
HotkeyAccess.read = readHotkey
```

Add, in `HotkeyController.swift` (bottom of file):

```swift
/// Lets the SwiftUI Settings view reach the controllers created in AppDelegate.
@MainActor
enum HotkeyAccess {
    static var compose: HotkeyController?
    static var read: HotkeyController?
}
```

- [ ] **Step 2: Update the compose recorder + add the read recorder in Settings**

In `SettingsWindow.swift`, replace the single shortcut row. Change the `@State` and the recorder block. New `@State`:

```swift
@State private var composeDisplay: String = HotkeyAccess.compose?.display ?? "⌥⌘T"
@State private var readDisplay: String = HotkeyAccess.read?.display ?? "⌥⌘R"
```

Replace the existing "Shortcut:" `HStack` with two rows:

```swift
HStack(spacing: 8) {
    Text("Compose (English → 中):").font(.callout)
    HotkeyRecorder(current: composeDisplay) { keyCode, mods, display in
        if HotkeyAccess.compose?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
            composeDisplay = display; status = "Compose shortcut set to \(display)."
        } else { status = "That shortcut is already in use — try another." }
    }.frame(width: 150, height: 26)
}
HStack(spacing: 8) {
    Text("Read (中 → English):").font(.callout)
    HotkeyRecorder(current: readDisplay) { keyCode, mods, display in
        if HotkeyAccess.read?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
            readDisplay = display; status = "Read shortcut set to \(display)."
        } else { status = "That shortcut is already in use — try another." }
    }.frame(width: 150, height: 26)
}
```

Update the caption text below to mention both: "Compose translates what you typed in place; Read shows the English for selected Chinese in a popup."

- [ ] **Step 3: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1`
Expected: `Build complete!`

- [ ] **Step 4: Manually verify both recorders**

Run `./scripts/build-bar.sh && killall TypeTranslatorBar 2>/dev/null; open "build/Type Translator.app"`. In Settings: change the Read shortcut to e.g. ⌥⌘E, confirm the menu updates and the new combo triggers the read popup; the Compose shortcut still works independently. Restart the app and confirm both persist.

- [ ] **Step 5: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/SettingsWindow.swift TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift TypeTranslatorApp/Sources/TypeTranslatorBar/HotkeyController.swift
git commit -m "feat: customizable read shortcut in Settings"
```

---

### Task 6: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the read direction**

In `README.md`, under "How it works" / "Usage", add the Read hotkey: select Chinese text anywhere and press ⌥⌘R to see the English in a popup near the cursor (read-only, nothing is changed). Note both shortcuts are customizable in Settings.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document read (zh-TW to English) hotkey"
```

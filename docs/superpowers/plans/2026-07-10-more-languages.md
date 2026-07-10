# More Languages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Compose translate English → a chosen target language and Read translate a foreign selection → English (source auto-detected online, or a chosen language offline), via two menu-bar language pickers.

**Architecture:** The engines already take source/target codes; fix Google to pass exact codes through (so Traditional vs Simplified Chinese are distinct) and omit the source when auto-detecting. Add an app-level curated language list + a UserDefaults-backed `LanguagePrefs`, two menu-bar submenus that set it, and have `TranslateService` read the current compose/read language from it.

**Tech Stack:** Swift 5.9 (Swift 5 mode), AppKit, SwiftPM, XCTest. macOS 14 floor; Apple Translation APIs gated to macOS 15+.

## Global Constraints

- `swift-tools-version: 5.9`; platform floor `.macOS(.v14)`; macOS-15-only API gated with `@available(macOS 15.0, *)`.
- All engines remain `Sendable` (or `@unchecked Sendable`).
- Zero compiler warnings on a clean build.
- Language codes are exact engine codes: `zh-TW`, `zh-CN`, `ja`, `ko`, `es`, `fr`, `de`, `th`, `vi`. The sentinel `"auto"` means "auto-detect" (read only).
- Compose source is always `en`; Read target is always `en`.
- Defaults: compose target `zh-TW`; read source `auto`.
- Core tests: `swift test --package-path TranslationCore`. App build: `swift build --package-path TypeTranslatorApp`.

---

### Task 1: Engine code-passthrough + auto-detect

**Files:**
- Modify: `TranslationCore/Sources/TranslationCore/GoogleEngine.swift`
- Modify: `TranslationCore/Sources/TranslationCore/AppleEngine.swift`
- Modify: `TranslationCore/Sources/TranslationCore/DeepLEngine.swift`
- Modify test: `TranslationCore/Tests/TranslationCoreTests/GoogleEngineTests.swift`
- Modify test: `TranslationCore/Tests/TranslationCoreTests/DeepLEngineTests.swift`
- Create test: `TranslationCore/Tests/TranslationCoreTests/AppleEngineTests.swift`

**Interfaces:**
- Produces (behavioral contract, signature unchanged): `GoogleEngine.translate` sends the exact `target` code and omits the `source` form field when `source == "auto"`; `AppleEngine.translate` throws a `TranslationError` when `source == "auto"`.

- [ ] **Step 1: Write the failing Google tests first**

In `GoogleEngineTests.swift`, add three tests:

```swift
func testAutoDetectOmitsSource() async throws {
    let http = MockHTTP(.success(HTTPResponse(status: 200, body: okBody("hello"))))
    let engine = GoogleEngine(secrets: secrets("k"), http: http)
    _ = try await engine.translate("你好", from: "auto", to: "en")
    XCTAssertNil(http.lastForm["source"])            // omitted for auto-detect
    XCTAssertEqual(http.lastForm["target"], "en")
}

func testTargetCodePassedThroughVerbatim() async throws {
    let http = MockHTTP(.success(HTTPResponse(status: 200, body: okBody("こんにちは"))))
    let engine = GoogleEngine(secrets: secrets("k"), http: http)
    _ = try await engine.translate("hello", from: "en", to: "ja")
    XCTAssertEqual(http.lastForm["target"], "ja")
    XCTAssertEqual(http.lastForm["source"], "en")
}

func testSimplifiedNotCollapsedToTraditional() async throws {
    let http = MockHTTP(.success(HTTPResponse(status: 200, body: okBody("电脑"))))
    let engine = GoogleEngine(secrets: secrets("k"), http: http)
    _ = try await engine.translate("computer", from: "en", to: "zh-CN")
    XCTAssertEqual(http.lastForm["target"], "zh-CN")   // NOT forced to zh-TW
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `swift test --package-path TranslationCore 2>&1 | grep -E "failed|error:" | head`
Expected: `testAutoDetectOmitsSource` fails (source present) and `testSimplifiedNotCollapsedToTraditional` fails (target is `zh-TW`), because `googleLang` still forces `zh*`→`zh-TW` and always sends `source`.

- [ ] **Step 3: Update GoogleEngine**

In `GoogleEngine.swift`, delete the `googleLang(_:)` helper entirely and replace the `translate` body's form construction:

```swift
public func translate(_ text: String, from source: String, to target: String) async throws -> String {
    guard let key = secrets.get(googleKeyName), !key.isEmpty else { throw TranslationError.noAPIKey }
    let url = URL(string: "https://\(host)/language/translate/v2")!
    var form = [
        "q": text,
        "target": target,       // exact code (zh-TW, zh-CN, ja, ko, …)
        "format": "text",
        "key": key,
    ]
    // Omit `source` so Google auto-detects when the caller passes "auto".
    if source != "auto" { form["source"] = source }

    let resp: HTTPResponse
    do { resp = try await http.post(url: url, headers: [:], form: form) }
    catch { throw TranslationError.network("\(error)") }

    switch resp.status {
    case 200: break
    case 429: throw TranslationError.quotaExceeded
    default: throw TranslationError.http(resp.status)
    }

    struct Payload: Decodable {
        struct DataField: Decodable {
            struct Translation: Decodable { let translatedText: String }
            let translations: [Translation]
        }
        let data: DataField
    }
    guard let payload = try? JSONDecoder().decode(Payload.self, from: resp.body),
          let translated = payload.data.translations.first?.translatedText, !translated.isEmpty else {
        throw TranslationError.empty
    }
    return Self.unescapeHTML(translated)
}
```

(`unescapeHTML` / `decodeNumericEntities` are unchanged.)

- [ ] **Step 4: Run Google tests to confirm they pass**

Run: `swift test --package-path TranslationCore --filter GoogleEngineTests 2>&1 | grep -E "Executed|failed" | tail -2`
Expected: all GoogleEngineTests pass (the three new + the existing ones, since existing tests use exact codes like `en`/`zh-TW`).

- [ ] **Step 5: Update AppleEngine to reject auto-detect**

In `AppleEngine.swift`, in the `#if canImport(Translation)` implementation, add a guard as the first line of `translate`:

```swift
public func translate(_ text: String, from source: String, to target: String) async throws -> String {
    // The on-device framework cannot auto-detect a language; offline Read must
    // specify a source. Fail fast so FallbackChain surfaces it cleanly.
    guard source != "auto" else {
        throw TranslationError.network("apple: cannot auto-detect language")
    }
    let config = TranslationSession.Configuration(
        source: Locale.Language(identifier: source),
        target: Locale.Language(identifier: target)
    )
    // ... rest unchanged ...
```

The `#else` stub already throws for any input, so it needs no change.

- [ ] **Step 6: Add the AppleEngine auto-detect test**

Create `AppleEngineTests.swift`:

```swift
import XCTest
@testable import TranslationCore

final class AppleEngineTests: XCTestCase {
    func testAutoSourceThrows() async {
        // AppleEngine's real implementation is @available(macOS 15.0, *), so its
        // instantiation must be guarded. On older systems the test is a no-op.
        // "auto" must be rejected before any session work.
        guard #available(macOS 15.0, *) else { return }
        let engine = AppleEngine()
        await XCTAssertThrowsErrorAsync(try await engine.translate("你好", from: "auto", to: "en")) { error in
            XCTAssertTrue(error is TranslationError)
        }
    }
}
```

- [ ] **Step 7: Update DeepLEngine to distinguish Traditional/Simplified and support auto**

In `DeepLEngine.swift`, replace `deepLTarget` and `deepLSource`, and omit `source_lang` for auto:

```swift
private func deepLTarget(_ code: String) -> String {
    switch code.lowercased() {
    case "zh-tw", "zh-hant": return "ZH-HANT"
    case "zh-cn", "zh-hans": return "ZH-HANS"
    default: return code.uppercased()
    }
}
private func deepLSource(_ code: String) -> String {
    code.lowercased().hasPrefix("zh") ? "ZH" : code.uppercased()
}
```

And in `translate`, build the form so `source_lang` is omitted for auto:

```swift
var form = ["text": text, "target_lang": deepLTarget(target)]
if source != "auto" { form["source_lang"] = deepLSource(source) }
```

- [ ] **Step 8: Add a DeepL Simplified test**

In `DeepLEngineTests.swift`, add:

```swift
func testSimplifiedTargetMapsToZhHans() async throws {
    let json = #"{"translations":[{"text":"电脑"}]}"#.data(using: .utf8)!
    let http = MockHTTP(.success(HTTPResponse(status: 200, body: json)))
    let engine = DeepLEngine(secrets: secrets("k"), http: http)
    _ = try await engine.translate("computer", from: "en", to: "zh-CN")
    XCTAssertEqual(http.lastForm["target_lang"], "ZH-HANS")
}
```

- [ ] **Step 9: Run the full core suite + build the app**

Run: `swift test --package-path TranslationCore 2>&1 | grep -E "Executed [0-9]+ tests|error:|warning:" | tail -2`
Expected: `Executed 41 tests, with 0 failures` (36 existing + 3 Google + 1 Apple + 1 DeepL), zero warnings.
Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1`
Expected: `Build complete!` (compose call site still passes exact `en`/`zh-TW`).

- [ ] **Step 10: Commit**

```bash
git add TranslationCore
git commit -m "feat: engines pass exact language codes + Google auto-detect (omit source)"
```

---

### Task 2: Curated language list + LanguagePrefs

**Files:**
- Create: `TypeTranslatorApp/Sources/TypeTranslatorBar/Language.swift`

**Interfaces:**
- Produces: `struct Language { let code: String; let name: String }`; `enum Languages { static let all: [Language]; static let autoCode = "auto"; static func name(for: String) -> String }`; `@MainActor enum LanguagePrefs { static var composeTargetCode: String; static var readSourceCode: String }`.

- [ ] **Step 1: Create Language.swift**

```swift
import Foundation

/// A translation language offered in the menus.
struct Language: Equatable {
    let code: String    // exact engine code, e.g. "zh-TW", "ja"
    let name: String    // native display name shown in the menu
}

/// The curated, baked-in language list. Add an entry here to offer more.
enum Languages {
    static let autoCode = "auto"

    static let all: [Language] = [
        Language(code: "zh-TW", name: "繁體中文 (Chinese, Traditional)"),
        Language(code: "zh-CN", name: "简体中文 (Chinese, Simplified)"),
        Language(code: "ja", name: "日本語 (Japanese)"),
        Language(code: "ko", name: "한국어 (Korean)"),
        Language(code: "es", name: "Español (Spanish)"),
        Language(code: "fr", name: "Français (French)"),
        Language(code: "de", name: "Deutsch (German)"),
        Language(code: "th", name: "ไทย (Thai)"),
        Language(code: "vi", name: "Tiếng Việt (Vietnamese)"),
    ]

    /// Display name for a code; `"auto"` → "Auto-detect"; unknown → the code.
    static func name(for code: String) -> String {
        if code == autoCode { return "Auto-detect" }
        return all.first { $0.code == code }?.name ?? code
    }
}

/// UserDefaults-backed current language selections, reachable from the menu
/// (AppDelegate) and TranslateService.
@MainActor
enum LanguagePrefs {
    private static var defaults: UserDefaults { .standard }

    /// Compose target (English → this). Default Traditional Chinese.
    static var composeTargetCode: String {
        get { defaults.string(forKey: "composeTargetCode") ?? "zh-TW" }
        set { defaults.set(newValue, forKey: "composeTargetCode") }
    }

    /// Read source (this → English). Default auto-detect.
    static var readSourceCode: String {
        get { defaults.string(forKey: "readSourceCode") ?? Languages.autoCode }
        set { defaults.set(newValue, forKey: "readSourceCode") }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 3: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/Language.swift
git commit -m "feat: curated language list + UserDefaults-backed LanguagePrefs"
```

---

### Task 3: TranslateService uses the selected languages

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/TranslateService.swift`

**Interfaces:**
- Consumes: `LanguagePrefs.composeTargetCode`, `LanguagePrefs.readSourceCode`, `Languages.autoCode`.

- [ ] **Step 1: Remove the hardcoded target constant**

In `TranslateService.swift`, delete the stored `private let target = "zh-TW"` line (if present).

- [ ] **Step 2: Compose uses the selected target**

Find the compose translate call (in `translateClipboard`):

```swift
let mandarin = try await self.engine.translate(english, from: "en", to: self.target)
```

Replace with:

```swift
let mandarin = try await self.engine.translate(english, from: "en", to: LanguagePrefs.composeTargetCode)
```

- [ ] **Step 3: Read uses the selected source + a clearer offline hint**

In `translateSelectionToPopup`, find the read translate call and its catch. Replace:

```swift
let english = try await self.engine.translate(chinese, from: "zh-TW", to: "en")
```

with:

```swift
let english = try await self.engine.translate(chinese, from: LanguagePrefs.readSourceCode, to: "en")
```

And replace the failure popup line in that method's `catch` with a source-aware message:

```swift
} catch {
    let hint = LanguagePrefs.readSourceCode == Languages.autoCode
        ? "Couldn't translate. If you're offline, pick a Read language in the menu."
        : "Couldn't translate — check your connection or API key."
    ResultPopup.shared.show(hint, at: cursor)
    self.finishRead(status: "⚠", restore: saved, to: pb)
}
```

- [ ] **Step 4: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 5: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/TranslateService.swift
git commit -m "feat: compose/read use the selected languages from LanguagePrefs"
```

---

### Task 4: Menu-bar language pickers

**Files:**
- Modify: `TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift`

**Interfaces:**
- Consumes: `Languages.all`, `Languages.autoCode`, `Languages.name(for:)`, `LanguagePrefs`.
- Produces: two submenus ("Compose language", "Read language") whose selections update `LanguagePrefs`, the checkmarks, and the compose/read menu-item titles.

- [ ] **Step 1: Add stored properties for the submenus**

In `AppDelegate.swift`, near the other menu properties, add:

```swift
private var composeLangMenu: NSMenu!
private var readLangMenu: NSMenu!
```

- [ ] **Step 2: Build the two submenus after the compose/read menu items**

In the menu construction, right after `menu.addItem(readItem)` (and before the following separator), insert:

```swift
composeLangMenu = NSMenu()
for lang in Languages.all {
    let item = NSMenuItem(title: lang.name, action: #selector(selectComposeLanguage(_:)), keyEquivalent: "")
    item.representedObject = lang.code
    item.target = self
    composeLangMenu.addItem(item)
}
let composeLangItem = NSMenuItem(title: "Compose language", action: nil, keyEquivalent: "")
composeLangItem.submenu = composeLangMenu
menu.addItem(composeLangItem)

readLangMenu = NSMenu()
let autoItem = NSMenuItem(title: "Auto-detect", action: #selector(selectReadLanguage(_:)), keyEquivalent: "")
autoItem.representedObject = Languages.autoCode
autoItem.target = self
readLangMenu.addItem(autoItem)
for lang in Languages.all {
    let item = NSMenuItem(title: lang.name, action: #selector(selectReadLanguage(_:)), keyEquivalent: "")
    item.representedObject = lang.code
    item.target = self
    readLangMenu.addItem(item)
}
let readLangItem = NSMenuItem(title: "Read language", action: nil, keyEquivalent: "")
readLangItem.submenu = readLangMenu
menu.addItem(readLangItem)
```

- [ ] **Step 3: Add the selection handlers + a refresh method**

Add these methods to `AppDelegate`:

```swift
@objc private func selectComposeLanguage(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    LanguagePrefs.composeTargetCode = code
    refreshLanguageMenus()
}

@objc private func selectReadLanguage(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    LanguagePrefs.readSourceCode = code
    refreshLanguageMenus()
}

/// Sync checkmarks and the compose/read menu-item titles to the current
/// selections. Also the single source of truth for those two titles.
private func refreshLanguageMenus() {
    let compose = LanguagePrefs.composeTargetCode
    let read = LanguagePrefs.readSourceCode
    for item in composeLangMenu.items {
        item.state = (item.representedObject as? String == compose) ? .on : .off
    }
    for item in readLangMenu.items {
        item.state = (item.representedObject as? String == read) ? .on : .off
    }
    translateItem.title = "Translate what I typed → \(Languages.name(for: compose))  (\(composeHotkey.display))"
    readItem.title = "Read selection (\(Languages.name(for: read)))  (\(readHotkey.display))"
}
```

- [ ] **Step 4: Route hotkey-label updates and initial state through refreshLanguageMenus**

The compose/read menu titles now include the language, so make `refreshLanguageMenus` the sole writer. Replace the two `onChange` closures (set in Task 3 of the reverse-translation work) so they call `refreshLanguageMenus()`:

```swift
composeHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
readHotkey.onChange = { [weak self] _ in self?.refreshLanguageMenus() }
```

And call `refreshLanguageMenus()` once at the end of `applicationDidFinishLaunching` (after both hotkeys are registered and the menus exist) to set the initial checkmarks and titles.

- [ ] **Step 5: Build**

Run: `swift build --package-path TypeTranslatorApp 2>&1 | tail -1`
Expected: `Build complete!`, zero warnings.

- [ ] **Step 6: Manually verify (controller/user)**

Run `./scripts/build-bar.sh && killall TypeTranslatorBar 2>/dev/null; open "build/Type Translator.app"`.
- Menu shows "Compose language ▸" (checkmark on 繁體中文) and "Read language ▸" (checkmark on Auto-detect).
- Pick Japanese under Compose language → compose item shows "→ 日本語"; typing English + ⌥⌘T now produces Japanese.
- Pick a specific Read language → read item title updates; ⌥⌘R uses it. Leaving Read on Auto-detect translates any selected foreign text to English.
- Selections persist across an app relaunch.

- [ ] **Step 7: Commit**

```bash
git add TypeTranslatorApp/Sources/TypeTranslatorBar/AppDelegate.swift
git commit -m "feat: menu-bar Compose/Read language pickers"
```

---

### Task 5: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document multi-language**

In `README.md` Usage section, note that Compose translates English → the language chosen in the menu's "Compose language" submenu (default Traditional Chinese), and Read translates a selection → English using "Read language" (Auto-detect by default; pick a specific language to work offline). List the available languages.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document multi-language compose/read pickers"
```

# Type Translator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS input method that translates typed English into Taiwanese Mandarin (Traditional, zh-TW) inline in any app, with a DeepL primary engine and an Apple on-device fallback.

**Architecture:** The entire translation brain lives in a standalone Swift Package (`TranslationCore`) that is fully unit-testable with `swift test` — no Xcode or input-method plumbing required. A thin Xcode input-method app (`TypeTranslator`) imports the package and adds the `IMKInputController` (keystroke/composing logic) and a small Settings window. The engine layer is a protocol with `DeepLEngine`, `AppleEngine`, and a `FallbackChain` that tries DeepL then falls back to Apple.

**Tech Stack:** Swift 5.9+, InputMethodKit, Swift Concurrency (async/await), URLSession (DeepL REST), Apple Translation framework (on-device), Security framework (Keychain), Xcode, XCTest / SwiftPM.

## Global Constraints

- Target OS: macOS 26 (present on the build machine). The `TranslationCore` package pins swift-tools-version 5.9 with platform floor `.macOS(.v14)` (`.macOS(.v15)` would force tools-version 6.0). macOS-15-only APIs — the Apple Translation framework in Task 5 — are gated with `@available(macOS 15.0, *)`; the Xcode app target (Task 6) is macOS 15+.
- Target language fixed to Taiwanese Mandarin Traditional; DeepL target code `ZH-HANT`, Apple locale `zh-TW`. Engines still accept a target parameter (no hardcoding inside logic).
- Source language: English (`EN`).
- Free-to-run: DeepL **free** endpoint host `api-free.deepl.com`; Apple engine is the always-available fallback.
- DeepL API key stored in the macOS Keychain — never in a plaintext file or in source.
- No word-by-word translation; sentence-level only.
- While any composing (underlined) text exists, the input method must consume Enter so the host app never sends prematurely.
- TDD for all `TranslationCore` logic; the `IMKInputController` and Apple engine are verified manually (documented per task).
- App installs to `~/Library/Input Methods/`; development/self-signed signature is acceptable.

---

### Task 1: Scaffold `TranslationCore` package + engine protocol and errors

**Files:**
- Create: `TranslationCore/Package.swift`
- Create: `TranslationCore/Sources/TranslationCore/TranslationEngine.swift`
- Test: `TranslationCore/Tests/TranslationCoreTests/TranslationEngineTests.swift`

**Interfaces:**
- Produces:
  - `protocol TranslationEngine { func translate(_ english: String, to target: String) async throws -> String }`
  - `enum TranslationError: Error, Equatable { case noAPIKey, quotaExceeded, network(String), http(Int), empty }`

- [ ] **Step 1: Create the package manifest**

Create `TranslationCore/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranslationCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranslationCore", targets: ["TranslationCore"]),
    ],
    targets: [
        .target(name: "TranslationCore"),
        .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `TranslationCore/Tests/TranslationCoreTests/TranslationEngineTests.swift`:

```swift
import XCTest
@testable import TranslationCore

final class TranslationEngineTests: XCTestCase {
    func testTranslationErrorEquatable() {
        XCTAssertEqual(TranslationError.quotaExceeded, TranslationError.quotaExceeded)
        XCTAssertNotEqual(TranslationError.http(456), TranslationError.http(500))
    }

    func testStubEngineConformsAndReturns() async throws {
        let stub: TranslationEngine = StubEngine(result: .success("你好"))
        let out = try await stub.translate("hi", to: "zh-TW")
        XCTAssertEqual(out, "你好")
    }
}

/// Test double reused across the package's tests.
struct StubEngine: TranslationEngine {
    let result: Result<String, TranslationError>
    var recordedCalls: (@Sendable (String, String) -> Void)? = nil
    func translate(_ english: String, to target: String) async throws -> String {
        recordedCalls?(english, target)
        switch result {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd TranslationCore && swift test`
Expected: FAIL — `cannot find 'TranslationError' in scope` / `TranslationEngine` undefined.

- [ ] **Step 4: Write minimal implementation**

Create `TranslationCore/Sources/TranslationCore/TranslationEngine.swift`:

```swift
import Foundation

/// A source of English→target translation. Implementations must be safe to call
/// concurrently and must throw `TranslationError` on failure.
public protocol TranslationEngine: Sendable {
    /// Translate `english` into `target` (e.g. "zh-TW"). Throws on failure.
    func translate(_ english: String, to target: String) async throws -> String
}

public enum TranslationError: Error, Equatable, Sendable {
    case noAPIKey
    case quotaExceeded
    case network(String)
    case http(Int)
    case empty
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd TranslationCore && swift test`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add TranslationCore
git commit -m "feat: TranslationCore package with engine protocol and errors"
```

---

### Task 2: Secret storage (`SecretStore` protocol + in-memory + Keychain)

**Files:**
- Create: `TranslationCore/Sources/TranslationCore/SecretStore.swift`
- Test: `TranslationCore/Tests/TranslationCoreTests/SecretStoreTests.swift`

**Interfaces:**
- Produces:
  - `protocol SecretStore { func get(_ key: String) -> String?; func set(_ value: String?, for key: String) }`
  - `final class InMemorySecretStore: SecretStore` (for tests / no-key runs)
  - `final class KeychainSecretStore: SecretStore` (real storage, exercised manually in the app)
  - Constant `let deepLKeyName = "deepl-api-key"`

**Rationale:** Keychain access from `swift test` on the command line can trigger prompts, so logic is tested against `InMemorySecretStore`; `KeychainSecretStore` is a thin wrapper verified in the running app (Task 8).

- [ ] **Step 1: Write the failing test**

Create `TranslationCore/Tests/TranslationCoreTests/SecretStoreTests.swift`:

```swift
import XCTest
@testable import TranslationCore

final class SecretStoreTests: XCTestCase {
    func testSetGetRoundTrip() {
        let store = InMemorySecretStore()
        XCTAssertNil(store.get(deepLKeyName))
        store.set("abc123", for: deepLKeyName)
        XCTAssertEqual(store.get(deepLKeyName), "abc123")
    }

    func testSetNilDeletes() {
        let store = InMemorySecretStore()
        store.set("abc123", for: deepLKeyName)
        store.set(nil, for: deepLKeyName)
        XCTAssertNil(store.get(deepLKeyName))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TranslationCore && swift test --filter SecretStoreTests`
Expected: FAIL — `cannot find 'InMemorySecretStore'` / `deepLKeyName`.

- [ ] **Step 3: Write minimal implementation**

Create `TranslationCore/Sources/TranslationCore/SecretStore.swift`:

```swift
import Foundation
import Security

public let deepLKeyName = "deepl-api-key"

public protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ value: String?, for key: String)
}

/// Thread-safe in-memory store for tests and no-key runs.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }
    public func set(_ value: String?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { storage[key] = value } else { storage[key] = nil }
    }
}

/// Keychain-backed store (generic password). Verified manually in the app.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "com.typetranslator.secrets") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var q = query(key)
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TranslationCore && swift test --filter SecretStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add TranslationCore
git commit -m "feat: SecretStore with in-memory and Keychain implementations"
```

---

### Task 3: `DeepLEngine` (primary, HTTP mockable)

**Files:**
- Create: `TranslationCore/Sources/TranslationCore/HTTPClient.swift`
- Create: `TranslationCore/Sources/TranslationCore/DeepLEngine.swift`
- Test: `TranslationCore/Tests/TranslationCoreTests/DeepLEngineTests.swift`

**Interfaces:**
- Consumes: `SecretStore`, `deepLKeyName`, `TranslationError`, `TranslationEngine`.
- Produces:
  - `struct HTTPResponse { let status: Int; let body: Data }`
  - `protocol HTTPClient { func post(url: URL, headers: [String:String], form: [String:String]) async throws -> HTTPResponse }`
  - `final class URLSessionHTTPClient: HTTPClient`
  - `final class DeepLEngine: TranslationEngine` with `init(secrets: SecretStore, http: HTTPClient, host: String = "api-free.deepl.com")`

**DeepL contract:** `POST https://<host>/v2/translate`, header `Authorization: DeepL-Auth-Key <key>`, form fields `text`, `source_lang=EN`, `target_lang=ZH-HANT`. Success JSON: `{"translations":[{"text":"..."}]}`. HTTP 456 = quota exceeded; 401/403 = bad key.

- [ ] **Step 1: Write the failing tests**

Create `TranslationCore/Tests/TranslationCoreTests/DeepLEngineTests.swift`:

```swift
import XCTest
@testable import TranslationCore

private final class MockHTTP: HTTPClient, @unchecked Sendable {
    var response: Result<HTTPResponse, Error>
    var lastURL: URL?
    var lastHeaders: [String: String] = [:]
    var lastForm: [String: String] = [:]
    init(_ response: Result<HTTPResponse, Error>) { self.response = response }
    func post(url: URL, headers: [String: String], form: [String: String]) async throws -> HTTPResponse {
        lastURL = url; lastHeaders = headers; lastForm = form
        return try response.get()
    }
}

final class DeepLEngineTests: XCTestCase {
    private func secrets(_ key: String?) -> SecretStore {
        let s = InMemorySecretStore(); if let key { s.set(key, for: deepLKeyName) }; return s
    }

    func testSuccessParsesTranslation() async throws {
        let json = #"{"translations":[{"text":"你好嗎"}]}"#.data(using: .utf8)!
        let http = MockHTTP(.success(HTTPResponse(status: 200, body: json)))
        let engine = DeepLEngine(secrets: secrets("k"), http: http)
        let out = try await engine.translate("how are you", to: "zh-TW")
        XCTAssertEqual(out, "你好嗎")
    }

    func testSendsCorrectRequest() async throws {
        let json = #"{"translations":[{"text":"嗨"}]}"#.data(using: .utf8)!
        let http = MockHTTP(.success(HTTPResponse(status: 200, body: json)))
        let engine = DeepLEngine(secrets: secrets("SECRET"), http: http)
        _ = try await engine.translate("hi", to: "zh-TW")
        XCTAssertEqual(http.lastURL?.absoluteString, "https://api-free.deepl.com/v2/translate")
        XCTAssertEqual(http.lastHeaders["Authorization"], "DeepL-Auth-Key SECRET")
        XCTAssertEqual(http.lastForm["target_lang"], "ZH-HANT")
        XCTAssertEqual(http.lastForm["source_lang"], "EN")
        XCTAssertEqual(http.lastForm["text"], "hi")
    }

    func testNoKeyThrows() async {
        let engine = DeepLEngine(secrets: secrets(nil), http: MockHTTP(.success(HTTPResponse(status: 200, body: Data()))))
        await XCTAssertThrowsErrorAsync(try await engine.translate("hi", to: "zh-TW")) {
            XCTAssertEqual($0 as? TranslationError, .noAPIKey)
        }
    }

    func testQuotaExceededThrows() async {
        let http = MockHTTP(.success(HTTPResponse(status: 456, body: Data())))
        let engine = DeepLEngine(secrets: secrets("k"), http: http)
        await XCTAssertThrowsErrorAsync(try await engine.translate("hi", to: "zh-TW")) {
            XCTAssertEqual($0 as? TranslationError, .quotaExceeded)
        }
    }

    func testNetworkErrorThrows() async {
        struct Boom: Error {}
        let http = MockHTTP(.failure(Boom()))
        let engine = DeepLEngine(secrets: secrets("k"), http: http)
        await XCTAssertThrowsErrorAsync(try await engine.translate("hi", to: "zh-TW")) {
            guard case .network = ($0 as? TranslationError) else { return XCTFail("expected .network") }
        }
    }
}

/// Async throwing assertion helper.
func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> some Any,
                              _ handler: (Error) -> Void) async {
    do { _ = try await expression(); XCTFail("expected error") }
    catch { handler(error) }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd TranslationCore && swift test --filter DeepLEngineTests`
Expected: FAIL — `HTTPClient` / `DeepLEngine` / `HTTPResponse` undefined.

- [ ] **Step 3: Write the HTTP client**

Create `TranslationCore/Sources/TranslationCore/HTTPClient.swift`:

```swift
import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol HTTPClient: Sendable {
    func post(url: URL, headers: [String: String], form: [String: String]) async throws -> HTTPResponse
}

public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func post(url: URL, headers: [String: String], form: [String: String]) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = form.map { key, value in
            let e = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
            return "\(e(key))=\(e(value))"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return HTTPResponse(status: status, body: data)
    }
}
```

- [ ] **Step 4: Write `DeepLEngine`**

Create `TranslationCore/Sources/TranslationCore/DeepLEngine.swift`:

```swift
import Foundation

public final class DeepLEngine: TranslationEngine {
    private let secrets: SecretStore
    private let http: HTTPClient
    private let host: String

    public init(secrets: SecretStore, http: HTTPClient, host: String = "api-free.deepl.com") {
        self.secrets = secrets; self.http = http; self.host = host
    }

    /// Maps our target locale to DeepL's language code.
    private func deepLTarget(_ target: String) -> String {
        target.lowercased().hasPrefix("zh") ? "ZH-HANT" : target.uppercased()
    }

    public func translate(_ english: String, to target: String) async throws -> String {
        guard let key = secrets.get(deepLKeyName), !key.isEmpty else { throw TranslationError.noAPIKey }
        let url = URL(string: "https://\(host)/v2/translate")!
        let headers = ["Authorization": "DeepL-Auth-Key \(key)"]
        let form = ["text": english, "source_lang": "EN", "target_lang": deepLTarget(target)]

        let resp: HTTPResponse
        do { resp = try await http.post(url: url, headers: headers, form: form) }
        catch { throw TranslationError.network("\(error)") }

        switch resp.status {
        case 200: break
        case 456: throw TranslationError.quotaExceeded
        default: throw TranslationError.http(resp.status)
        }

        struct Payload: Decodable { struct T: Decodable { let text: String }; let translations: [T] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: resp.body),
              let text = payload.translations.first?.text, !text.isEmpty else {
            throw TranslationError.empty
        }
        return text
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd TranslationCore && swift test --filter DeepLEngineTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add TranslationCore
git commit -m "feat: DeepLEngine with mockable HTTP client"
```

---

### Task 4: `FallbackChain` (DeepL → Apple)

**Files:**
- Create: `TranslationCore/Sources/TranslationCore/FallbackChain.swift`
- Test: `TranslationCore/Tests/TranslationCoreTests/FallbackChainTests.swift`

**Interfaces:**
- Consumes: `TranslationEngine`, `StubEngine` (from Task 1 tests), `TranslationError`.
- Produces: `final class FallbackChain: TranslationEngine` with `init(primary: TranslationEngine, fallback: TranslationEngine)` and a callback `var onFallback: (@Sendable (TranslationError) -> Void)?` invoked when it falls back.

- [ ] **Step 1: Write the failing tests**

Create `TranslationCore/Tests/TranslationCoreTests/FallbackChainTests.swift`:

```swift
import XCTest
@testable import TranslationCore

final class FallbackChainTests: XCTestCase {
    func testUsesPrimaryWhenHealthy() async throws {
        let chain = FallbackChain(primary: StubEngine(result: .success("DEEPL")),
                                  fallback: StubEngine(result: .success("APPLE")))
        let out = try await chain.translate("hi", to: "zh-TW")
        XCTAssertEqual(out, "DEEPL")
    }

    func testFallsBackOnPrimaryFailure() async throws {
        let chain = FallbackChain(primary: StubEngine(result: .failure(.quotaExceeded)),
                                  fallback: StubEngine(result: .success("APPLE")))
        let out = try await chain.translate("hi", to: "zh-TW")
        XCTAssertEqual(out, "APPLE")
    }

    func testFallsBackOnNoKey() async throws {
        let chain = FallbackChain(primary: StubEngine(result: .failure(.noAPIKey)),
                                  fallback: StubEngine(result: .success("APPLE")))
        let out = try await chain.translate("hi", to: "zh-TW")
        XCTAssertEqual(out, "APPLE")
    }

    func testReportsFallbackReason() async throws {
        let chain = FallbackChain(primary: StubEngine(result: .failure(.quotaExceeded)),
                                  fallback: StubEngine(result: .success("APPLE")))
        var reported: TranslationError?
        chain.onFallback = { reported = $0 }
        _ = try await chain.translate("hi", to: "zh-TW")
        XCTAssertEqual(reported, .quotaExceeded)
    }

    func testPropagatesWhenBothFail() async {
        let chain = FallbackChain(primary: StubEngine(result: .failure(.quotaExceeded)),
                                  fallback: StubEngine(result: .failure(.empty)))
        await XCTAssertThrowsErrorAsync(try await chain.translate("hi", to: "zh-TW")) {
            XCTAssertEqual($0 as? TranslationError, .empty)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd TranslationCore && swift test --filter FallbackChainTests`
Expected: FAIL — `FallbackChain` undefined.

- [ ] **Step 3: Write the implementation**

Create `TranslationCore/Sources/TranslationCore/FallbackChain.swift`:

```swift
import Foundation

/// Tries `primary`; on any `TranslationError`, reports the reason and tries `fallback`.
public final class FallbackChain: TranslationEngine, @unchecked Sendable {
    private let primary: TranslationEngine
    private let fallback: TranslationEngine
    public var onFallback: (@Sendable (TranslationError) -> Void)?

    public init(primary: TranslationEngine, fallback: TranslationEngine) {
        self.primary = primary; self.fallback = fallback
    }

    public func translate(_ english: String, to target: String) async throws -> String {
        do {
            return try await primary.translate(english, to: target)
        } catch let error as TranslationError {
            onFallback?(error)
            return try await fallback.translate(english, to: target)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd TranslationCore && swift test`
Expected: PASS (all tests across the package).

- [ ] **Step 5: Commit**

```bash
git add TranslationCore
git commit -m "feat: FallbackChain trying DeepL then Apple on-device"
```

---

### Task 5: `AppleEngine` (on-device fallback via Translation framework)

**Files:**
- Create: `TranslationCore/Sources/TranslationCore/AppleEngine.swift`
- Manual harness: `TranslationCore/Sources/appletest/main.swift` (optional CLI probe — see note)

**Interfaces:**
- Consumes: `TranslationEngine`, `TranslationError`.
- Produces: `final class AppleEngine: TranslationEngine` — `init()`. Uses Apple's `Translation` framework with locale `zh-TW`.

**Integration note (read first):** Apple's `Translation` framework is designed around SwiftUI's `.translationTask` modifier; a `TranslationSession` is normally vended to a SwiftUI view. Because our input method has no natural SwiftUI view for translation, `AppleEngine` hosts an offscreen SwiftUI view internally to obtain a session. This is the project's one genuinely tricky integration and is **verified manually inside the running app (Task 8/9)**, not in `swift test`. Implement to the interface below; if the offscreen-session approach needs adjustment during the app build, keep the public signature identical so `FallbackChain` is unaffected.

- [ ] **Step 1: Write `AppleEngine`**

Create `TranslationCore/Sources/TranslationCore/AppleEngine.swift`:

```swift
import Foundation
#if canImport(Translation)
import Translation
import SwiftUI

/// On-device translation via Apple's Translation framework (zh-TW).
/// Hosts an offscreen SwiftUI view to obtain a TranslationSession.
@available(macOS 15.0, *)
public final class AppleEngine: TranslationEngine, @unchecked Sendable {
    public init() {}

    public func translate(_ english: String, to target: String) async throws -> String {
        let config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: target)  // "zh-TW"
        )
        do {
            let session = try await SessionProvider.session(for: config)
            let response = try await session.translate(english)
            guard !response.targetText.isEmpty else { throw TranslationError.empty }
            return response.targetText
        } catch let e as TranslationError {
            throw e
        } catch {
            throw TranslationError.network("apple: \(error)")
        }
    }
}
#else
public final class AppleEngine: TranslationEngine, @unchecked Sendable {
    public init() {}
    public func translate(_ english: String, to target: String) async throws -> String {
        throw TranslationError.network("Translation framework unavailable")
    }
}
#endif
```

- [ ] **Step 2: Add the offscreen session provider**

Add to the same file (inside the `#if canImport(Translation)` block), a `SessionProvider` that attaches a hidden `.translationTask` to an offscreen `NSHostingView` and bridges the vended session to async/await via a continuation. Implement `static func session(for:) async throws -> TranslationSession`. During the app build (Task 8) this runs on the main actor with a real window; wire it so the first call triggers the system language-pack download prompt if the pack is missing.

- [ ] **Step 3: Verify it builds (compile-only here)**

Run: `cd TranslationCore && swift build`
Expected: builds without error. (Runtime behavior is verified in Task 9 inside the app, since the Translation session needs an app UI context.)

- [ ] **Step 4: Commit**

```bash
git add TranslationCore
git commit -m "feat: AppleEngine on-device translation (offscreen session)"
```

---

### Task 6: Xcode input-method app scaffold

**Files:**
- Create (via Xcode GUI): `TypeTranslator.xcodeproj` and target `TypeTranslator`
- Create: `TypeTranslator/TypeTranslator/main.swift`
- Create: `TypeTranslator/TypeTranslator/Info.plist` keys (edit)
- Modify: link local package `TranslationCore`

**Interfaces:**
- Consumes: `TranslationCore` (all public types).
- Produces: a launchable `.app` that registers as an input method and instantiates `TranslatorInputController` (Task 7) via `IMKServer`.

- [ ] **Step 1: Create the app target in Xcode**

In Xcode: File → New → Project → macOS → **App**, name `TypeTranslator`, language Swift, interface AppKit (uncheck SwiftUI lifecycle). Save inside the repo at `TypeTranslator/`.

- [ ] **Step 2: Add the local package dependency**

File → Add Package Dependencies → **Add Local…** → select the `TranslationCore` folder. Add `TranslationCore` to the app target's frameworks.

- [ ] **Step 3: Configure `Info.plist` for an input method**

Add these keys to the target's Info.plist:

```xml
<key>LSBackgroundOnly</key><true/>
<key>InputMethodConnectionName</key><string>TypeTranslator_Connection</string>
<key>InputMethodServerControllerClass</key><string>TypeTranslator.TranslatorInputController</string>
<key>tsInputMethodIconFileKey</key><string>icon.tiff</string>
<key>ComponentInputModeDict</key>
<dict>
  <key>tsInputModeListKey</key>
  <dict>
    <key>com.typetranslator.english-to-zhtw</key>
    <dict>
      <key>TISInputSourceID</key><string>com.typetranslator.english-to-zhtw</string>
      <key>tsInputModeAlternateMenuTitleKey</key><string>English → 台灣中文</string>
      <key>tsInputModeIsVisibleKey</key><true/>
      <key>tsInputModePrimaryInScriptKey</key><true/>
      <key>tsInputModeScriptKey</key><string>smRoman</string>
    </dict>
  </dict>
  <key>tsVisibleInputModeOrderedArrayKey</key>
  <array><string>com.typetranslator.english-to-zhtw</string></array>
</dict>
```

- [ ] **Step 4: Write the IMK server bootstrap**

Replace `main.swift` contents:

```swift
import Cocoa
import InputMethodKit

// Global server retained for the process lifetime.
var server: IMKServer!

let bundle = Bundle.main
server = IMKServer(name: bundle.infoDictionary?["InputMethodConnectionName"] as? String,
                   bundleIdentifier: bundle.bundleIdentifier)

let app = NSApplication.shared
app.run()
```

- [ ] **Step 5: Add a placeholder controller so it builds**

Create `TypeTranslator/TypeTranslator/TranslatorInputController.swift`:

```swift
import InputMethodKit

@objc(TranslatorInputController)
class TranslatorInputController: IMKInputController {
    // Filled in by Task 7.
}
```

- [ ] **Step 6: Build**

Run: `xcodebuild -project TypeTranslator/TypeTranslator.xcodeproj -scheme TypeTranslator -configuration Debug build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add TypeTranslator
git commit -m "feat: Xcode input-method app scaffold with IMKServer"
```

---

### Task 7: `TranslatorInputController` — composing buffer, trigger, preview, commit

**Files:**
- Modify: `TypeTranslator/TypeTranslator/TranslatorInputController.swift`

**Interfaces:**
- Consumes: `FallbackChain`, `DeepLEngine`, `AppleEngine`, `KeychainSecretStore`, `URLSessionHTTPClient` from `TranslationCore`.
- Produces: the working keystroke behavior described below.

**Behavior spec (manual acceptance — verify each in Step 6):**
1. Typing letters shows underlined English (marked text), nothing committed.
2. Typing a sentence-ending char (`.`, `?`, `!`) translates the buffer and replaces it with underlined Mandarin (preview). During the async call the buffer stays marked.
3. `Enter` while marked → commits the Mandarin as real text; the event is consumed (host app does NOT send).
4. `Enter` while nothing marked → returns `false` so the host app receives it (sends).
5. `Esc` while marked → discards translation, restores the pre-translation English as marked text; second `Esc` clears to empty.

- [ ] **Step 1: Implement the controller**

Replace the file contents:

```swift
import InputMethodKit
import TranslationCore

@objc(TranslatorInputController)
class TranslatorInputController: IMKInputController {
    private var englishBuffer = ""      // raw English typed
    private var previewMandarin: String? // set once translated
    private let engine: FallbackChain
    private let target = "zh-TW"

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        let secrets = KeychainSecretStore()
        let deepl = DeepLEngine(secrets: secrets, http: URLSessionHTTPClient())
        let apple = AppleEngine()
        self.engine = FallbackChain(primary: deepl, fallback: apple)
        super.init(server: server, delegate: delegate, client: inputClient)
    }

    private func sender() -> (IMKTextInput & IMKUnicodeTextInput)? {
        client() as? (IMKTextInput & IMKUnicodeTextInput)
    }

    private func showMarked(_ text: String) {
        let attr = NSAttributedString(string: text,
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        client()?.setMarkedText(attr, selectionRange: NSRange(location: text.count, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func commit(_ text: String) {
        client()?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        englishBuffer = ""; previewMandarin = nil
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else { return false }

        // Enter
        if event.keyCode == 36 { // Return
            if let mandarin = previewMandarin {
                commit(mandarin)
                return true            // consumed — does NOT send
            }
            if !englishBuffer.isEmpty { // untranslated text: commit English as-is
                commit(englishBuffer)
                return true
            }
            return false               // nothing marked → let host send
        }

        // Escape
        if event.keyCode == 53 { // Escape
            if previewMandarin != nil {
                previewMandarin = nil
                showMarked(englishBuffer)
                return true
            }
            if !englishBuffer.isEmpty {
                englishBuffer = ""
                client()?.setMarkedText(NSAttributedString(string: ""),
                    selectionRange: NSRange(location: 0, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
                return true
            }
            return false
        }

        // Backspace
        if event.keyCode == 51 { // Delete
            if previewMandarin != nil { return true } // ignore while previewing
            if !englishBuffer.isEmpty { englishBuffer.removeLast(); showMarked(englishBuffer); return true }
            return false
        }

        guard let chars = event.characters, !chars.isEmpty else { return false }

        // Typing after a preview exists starts a fresh buffer.
        if previewMandarin != nil { previewMandarin = nil; englishBuffer = "" }

        englishBuffer += chars
        showMarked(englishBuffer)

        // Sentence-ending trigger.
        if chars.count == 1, ".?!".contains(chars) {
            let toTranslate = englishBuffer
            Task { @MainActor in
                do {
                    let mandarin = try await self.engine.translate(toTranslate, to: self.target)
                    guard self.englishBuffer == toTranslate else { return } // superseded
                    self.previewMandarin = mandarin
                    self.showMarked(mandarin)
                } catch {
                    // Both engines failed: leave English marked so the user can still commit it.
                }
            }
        }
        return true
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project TypeTranslator/TypeTranslator.xcodeproj -scheme TypeTranslator -configuration Debug build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Install the built app**

Run:
```bash
cp -R ~/Library/Developer/Xcode/DerivedData/TypeTranslator-*/Build/Products/Debug/TypeTranslator.app ~/Library/Input\ Methods/
```
Then log out/in (or `killall TypeTranslator 2>/dev/null; open ~/Library/Input\ Methods/TypeTranslator.app`), and add the input source in System Settings → Keyboard → Input Sources → + → English → "English → 台灣中文".

- [ ] **Step 4: Manual acceptance test (no DeepL key yet → Apple path)**

Switch to the input source. In TextEdit, type `how are you?`. Expected: after `?`, underlined Mandarin preview appears; `Enter` commits it (nothing sent in a doc — text stays); typing a new sentence works; `Esc` restores English. Record pass/fail for each behavior in the spec above.

- [ ] **Step 5: Commit**

```bash
git add TypeTranslator
git commit -m "feat: TranslatorInputController with sentence-trigger preview and commit"
```

---

### Task 8: Settings window (DeepL key → Keychain, language-pack download)

**Files:**
- Create: `TypeTranslator/TypeTranslator/SettingsWindow.swift`
- Modify: `TypeTranslator/TypeTranslator/main.swift` (add a menu/hotkey to open settings)

**Interfaces:**
- Consumes: `KeychainSecretStore`, `deepLKeyName`, `AppleEngine` (to trigger pack download).
- Produces: a SwiftUI settings window with a secure field bound to the Keychain and a "Download zh-TW language pack" action.

- [ ] **Step 1: Implement the settings window**

Create `SettingsWindow.swift`:

```swift
import SwiftUI
import TranslationCore

struct SettingsView: View {
    private let secrets = KeychainSecretStore()
    @State private var key: String = ""
    @State private var status: String = ""

    var body: some View {
        Form {
            SecureField("DeepL API key", text: $key)
            HStack {
                Button("Save key") {
                    secrets.set(key.isEmpty ? nil : key, for: deepLKeyName)
                    status = key.isEmpty ? "Key cleared — using Apple only." : "Key saved."
                }
                Button("Download zh-TW pack") {
                    Task {
                        // First on-device translate call triggers the system download prompt.
                        _ = try? await AppleEngine().translate("hello", to: "zh-TW")
                        status = "If prompted, allow the language download."
                    }
                }
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 380)
        .onAppear { key = secrets.get(deepLKeyName) ?? "" }
    }
}
```

- [ ] **Step 2: Open settings from a status-bar menu**

In `main.swift`, before `app.run()`, add an `NSStatusItem` with a menu item "Settings…" that presents an `NSHostingController(rootView: SettingsView())` in a window, and a "Quit" item.

- [ ] **Step 3: Build, reinstall, verify**

Rebuild and reinstall (Task 7 Step 3). Open Settings from the menu bar; paste a DeepL free key; Save; type `hello.` in TextEdit and confirm the DeepL translation is used (differs subtly from Apple output; watch DeepL usage tick up in your DeepL account). Clear the key and confirm it falls back to Apple.

- [ ] **Step 4: Commit**

```bash
git add TypeTranslator
git commit -m "feat: settings window for DeepL key and language-pack download"
```

---

### Task 9: End-to-end acceptance in a real messenger + install doc

**Files:**
- Create: `README.md`
- Create: `scripts/install.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: a documented install flow and a verified end-to-end run.

- [ ] **Step 1: Write the install script**

Create `scripts/install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/TypeTranslator-*/Build/Products/Debug/TypeTranslator.app | head -1)
mkdir -p ~/Library/Input\ Methods
rm -rf ~/Library/Input\ Methods/TypeTranslator.app
cp -R "$APP" ~/Library/Input\ Methods/
killall TypeTranslator 2>/dev/null || true
open ~/Library/Input\ Methods/TypeTranslator.app
echo "Installed. Add the input source in System Settings → Keyboard → Input Sources."
```

Make it executable: `chmod +x scripts/install.sh`.

- [ ] **Step 2: End-to-end manual test in Messages**

Switch to the Type Translator input source. In Messages (to yourself or a test thread), type `are you free tonight?`:
- Preview Mandarin appears underlined.
- `Enter` #1 commits the Mandarin (message NOT sent).
- `Enter` #2 sends.
- Confirm no premature send occurred at any earlier point.
Repeat with Wi-Fi off to confirm Apple fallback still translates and the flow is unchanged.

- [ ] **Step 3: Write the README**

Create `README.md` documenting: what it is, requirements (macOS 15+), install via `scripts/install.sh`, adding the input source, getting a free DeepL key and pasting it in Settings, the typing flow (type → Enter to accept → Enter to send, Esc to cancel), and the DeepL→Apple fallback behavior.

- [ ] **Step 4: Commit**

```bash
git add README.md scripts/install.sh
git commit -m "docs: install script, README, and end-to-end acceptance"
```

---

## Self-Review Notes

- **Spec coverage:** sentence-level trigger (Task 7), preview + Enter/Enter/Esc semantics with no premature send (Task 7), DeepL primary (Task 3), Apple fallback (Task 5), FallbackChain (Task 4), Keychain key storage (Task 2/8), zh-TW fixed with target parameter retained (all engines), engine-layer unit tests + manual controller tests (Tasks 1–4 vs 7/9), install to `~/Library/Input Methods/` (Tasks 7/9).
- **Known risk:** Apple `Translation` framework session acquisition outside SwiftUI (Task 5) — isolated behind `AppleEngine`'s stable signature; if the offscreen-session approach needs revision it does not affect `FallbackChain` or the controller.
- **Type consistency:** `TranslationEngine.translate(_:to:)`, `TranslationError` cases, `SecretStore.get/set`, `deepLKeyName`, `HTTPClient.post`, `FallbackChain(primary:fallback:)` used identically across tasks.

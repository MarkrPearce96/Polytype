import XCTest
@testable import TranslationCore

private final class MockHTTP: HTTPClient, @unchecked Sendable {
    var response: Result<HTTPResponse, Error>
    var lastURL: URL?
    var lastForm: [String: String] = [:]
    init(_ response: Result<HTTPResponse, Error>) { self.response = response }
    func post(url: URL, headers: [String: String], form: [String: String]) async throws -> HTTPResponse {
        lastURL = url; lastForm = form
        return try response.get()
    }
}

final class GoogleEngineTests: XCTestCase {
    private func secrets(_ key: String?) -> SecretStore {
        let s = InMemorySecretStore(); if let key { s.set(key, for: googleKeyName) }; return s
    }

    private func okBody(_ text: String) -> Data {
        #"{"data":{"translations":[{"translatedText":"\#(text)"}]}}"#.data(using: .utf8)!
    }

    func testSuccessParsesTranslation() async throws {
        let http = MockHTTP(.success(HTTPResponse(status: 200, body: okBody("你好嗎"))))
        let engine = GoogleEngine(secrets: secrets("k"), http: http)
        let out = try await engine.translate("how are you", from: "en", to: "zh-TW")
        XCTAssertEqual(out, "你好嗎")
    }

    func testUnescapesHTMLEntities() async throws {
        // Google HTML-escapes output even in text mode.
        let http = MockHTTP(.success(HTTPResponse(status: 200, body: okBody("it&#39;s a &quot;test&quot; &amp; more"))))
        let engine = GoogleEngine(secrets: secrets("k"), http: http)
        let out = try await engine.translate("x", from: "en", to: "zh-TW")
        XCTAssertEqual(out, "it's a \"test\" & more")
    }

    func testUnescapesNumericEntities() {
        XCTAssertEqual(GoogleEngine.unescapeHTML("a&#215;b &#x2013; c"), "a×b – c")
    }

    func testSendsCorrectRequest() async throws {
        let http = MockHTTP(.success(HTTPResponse(status: 200, body: okBody("嗨"))))
        let engine = GoogleEngine(secrets: secrets("SECRET"), http: http)
        _ = try await engine.translate("hi", from: "en", to: "zh-TW")
        XCTAssertEqual(http.lastURL?.absoluteString, "https://translation.googleapis.com/language/translate/v2")
        XCTAssertEqual(http.lastForm["target"], "zh-TW")
        XCTAssertEqual(http.lastForm["source"], "en")
        XCTAssertEqual(http.lastForm["format"], "text")
        XCTAssertEqual(http.lastForm["q"], "hi")
        XCTAssertEqual(http.lastForm["key"], "SECRET")
    }

    func testNoKeyThrows() async {
        let engine = GoogleEngine(secrets: secrets(nil), http: MockHTTP(.success(HTTPResponse(status: 200, body: Data()))))
        await XCTAssertThrowsErrorAsync(try await engine.translate("hi", from: "en", to: "zh-TW")) {
            XCTAssertEqual($0 as? TranslationError, .noAPIKey)
        }
    }

    func testQuotaExceededThrows() async {
        let http = MockHTTP(.success(HTTPResponse(status: 429, body: Data())))
        let engine = GoogleEngine(secrets: secrets("k"), http: http)
        await XCTAssertThrowsErrorAsync(try await engine.translate("hi", from: "en", to: "zh-TW")) {
            XCTAssertEqual($0 as? TranslationError, .quotaExceeded)
        }
    }

    func testForbiddenThrowsHTTPStatus() async {
        // 403 = key invalid / API not enabled / billing off — surfaces as .http so
        // FallbackChain moves on to the next engine.
        let http = MockHTTP(.success(HTTPResponse(status: 403, body: Data())))
        let engine = GoogleEngine(secrets: secrets("k"), http: http)
        await XCTAssertThrowsErrorAsync(try await engine.translate("hi", from: "en", to: "zh-TW")) {
            XCTAssertEqual($0 as? TranslationError, .http(403))
        }
    }

    func testEmptyBodyThrowsEmpty() async {
        let http = MockHTTP(.success(HTTPResponse(status: 200, body: "{}".data(using: .utf8)!)))
        let engine = GoogleEngine(secrets: secrets("k"), http: http)
        await XCTAssertThrowsErrorAsync(try await engine.translate("hi", from: "en", to: "zh-TW")) {
            XCTAssertEqual($0 as? TranslationError, .empty)
        }
    }

    func testNetworkErrorThrows() async {
        struct Boom: Error {}
        let engine = GoogleEngine(secrets: secrets("k"), http: MockHTTP(.failure(Boom())))
        await XCTAssertThrowsErrorAsync(try await engine.translate("hi", from: "en", to: "zh-TW")) {
            guard case .network = ($0 as? TranslationError) else { return XCTFail("expected .network") }
        }
    }

    func testReverseDirectionRequest() async throws {
        let http = MockHTTP(.success(HTTPResponse(status: 200, body: okBody("how are you"))))
        let engine = GoogleEngine(secrets: secrets("k"), http: http)
        _ = try await engine.translate("你好嗎", from: "zh-TW", to: "en")
        XCTAssertEqual(http.lastForm["source"], "zh-TW")
        XCTAssertEqual(http.lastForm["target"], "en")
        XCTAssertEqual(http.lastForm["q"], "你好嗎")
    }

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
}

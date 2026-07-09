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

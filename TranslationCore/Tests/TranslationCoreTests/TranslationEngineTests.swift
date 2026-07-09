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

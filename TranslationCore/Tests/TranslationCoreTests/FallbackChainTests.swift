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

import XCTest
@testable import TranslationCore

/// Thread-safe mutable holder so a `@Sendable` callback can record a value
/// without a data-race warning (mirrors InMemorySecretStore's NSLock pattern).
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

final class FallbackChainTests: XCTestCase {
    func testUsesPrimaryWhenHealthy() async throws {
        let lastSource = Box<String?>(nil)
        let lastTarget = Box<String?>(nil)
        let primary = StubEngine(result: .success("DEEPL")) { _, source, target in
            lastSource.value = source
            lastTarget.value = target
        }
        let chain = FallbackChain(primary: primary,
                                  fallback: StubEngine(result: .success("APPLE")))
        let out = try await chain.translate("hi", from: "en", to: "zh-TW")
        XCTAssertEqual(out, "DEEPL")
        XCTAssertEqual(lastSource.value, "en")
        XCTAssertEqual(lastTarget.value, "zh-TW")
    }

    func testFallsBackOnPrimaryFailure() async throws {
        let chain = FallbackChain(primary: StubEngine(result: .failure(.quotaExceeded)),
                                  fallback: StubEngine(result: .success("APPLE")))
        let out = try await chain.translate("hi", from: "en", to: "zh-TW")
        XCTAssertEqual(out, "APPLE")
    }

    func testFallsBackOnNoKey() async throws {
        let chain = FallbackChain(primary: StubEngine(result: .failure(.noAPIKey)),
                                  fallback: StubEngine(result: .success("APPLE")))
        let out = try await chain.translate("hi", from: "en", to: "zh-TW")
        XCTAssertEqual(out, "APPLE")
    }

    func testReportsFallbackReason() async throws {
        let chain = FallbackChain(primary: StubEngine(result: .failure(.quotaExceeded)),
                                  fallback: StubEngine(result: .success("APPLE")))
        let reported = Box<TranslationError?>(nil)
        chain.onFallback = { reported.value = $0 }
        _ = try await chain.translate("hi", from: "en", to: "zh-TW")
        XCTAssertEqual(reported.value, .quotaExceeded)
    }

    func testPropagatesWhenBothFail() async {
        let chain = FallbackChain(primary: StubEngine(result: .failure(.quotaExceeded)),
                                  fallback: StubEngine(result: .failure(.empty)))
        await XCTAssertThrowsErrorAsync(try await chain.translate("hi", from: "en", to: "zh-TW")) {
            XCTAssertEqual($0 as? TranslationError, .empty)
        }
    }
}

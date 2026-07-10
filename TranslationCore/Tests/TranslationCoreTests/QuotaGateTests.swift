import XCTest
@testable import TranslationCore

private final class FakeStore2: UsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ints: [String: Int] = [:]; private var strings: [String: String] = [:]
    private var bools: [String: Bool] = [:]; private var doubles: [String: Double] = [:]
    func int(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return ints[key] ?? 0 }
    func setInt(_ v: Int, _ key: String) { lock.lock(); ints[key] = v; lock.unlock() }
    func string(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return strings[key] }
    func setString(_ v: String?, _ key: String) { lock.lock(); strings[key] = v; lock.unlock() }
    func bool(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return bools[key] ?? false }
    func setBool(_ v: Bool, _ key: String) { lock.lock(); bools[key] = v; lock.unlock() }
    func double(_ k: String) -> Double { lock.lock(); defer { lock.unlock() }; return doubles[k] ?? 0 }
    func setDouble(_ v: Double, _ k: String) { lock.lock(); doubles[k] = v; lock.unlock() }
}

private final class SpyEngine: TranslationEngine, @unchecked Sendable {
    var called = false
    var result: Result<String, Error>
    init(_ result: Result<String, Error>) { self.result = result }
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        called = true
        return try result.get()
    }
}

final class QuotaGateTests: XCTestCase {
    private func meter() -> UsageMeter {
        UsageMeter(store: FakeStore2(), now: { Date(timeIntervalSinceReferenceDate: 800_000_000) })
    }

    func testUnderCapDelegatesAndRecords() async throws {
        let m = meter()
        let spy = SpyEngine(.success("你好"))
        let gate = QuotaGate(primary: spy, meter: m)
        let out = try await gate.translate("hello", from: "en", to: "zh-TW")   // 5 scalars
        XCTAssertEqual(out, "你好")
        XCTAssertTrue(spy.called)
        XCTAssertEqual(m.used, 5)
    }

    func testOverCapThrowsWithoutCallingPrimary() async {
        let m = meter()
        m.record(490_000)                                   // at the cap
        let spy = SpyEngine(.success("x"))
        let gate = QuotaGate(primary: spy, meter: m)
        await XCTAssertThrowsErrorAsync(try await gate.translate("hi", from: "en", to: "zh-TW")) {
            XCTAssertEqual($0 as? TranslationError, .quotaExceeded)
        }
        XCTAssertFalse(spy.called)
        XCTAssertEqual(m.used, 490_000)                     // unchanged
    }

    func testPrimaryErrorPropagatesAndRecordsNothing() async {
        struct Boom: Error {}
        let m = meter()
        let spy = SpyEngine(.failure(Boom()))
        let gate = QuotaGate(primary: spy, meter: m)
        await XCTAssertThrowsErrorAsync(try await gate.translate("hello", from: "en", to: "zh-TW")) { _ in }
        XCTAssertEqual(m.used, 0)                           // not recorded on failure
    }
}

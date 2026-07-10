import XCTest
@testable import TranslationCore

private final class FakeStore: UsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ints: [String: Int] = [:]
    private var strings: [String: String] = [:]
    private var bools: [String: Bool] = [:]
    func int(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return ints[key] ?? 0 }
    func setInt(_ v: Int, _ key: String) { lock.lock(); ints[key] = v; lock.unlock() }
    func string(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return strings[key] }
    func setString(_ v: String?, _ key: String) { lock.lock(); strings[key] = v; lock.unlock() }
    func bool(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return bools[key] ?? false }
    func setBool(_ v: Bool, _ key: String) { lock.lock(); bools[key] = v; lock.unlock() }
}

final class UsageMeterTests: XCTestCase {
    private func meter(month: @escaping @Sendable () -> String) -> UsageMeter {
        UsageMeter(store: FakeStore(), month: month)
    }

    func testRecordAccumulates() {
        let m = meter { "2026-7" }
        m.record(100); m.record(50)
        XCTAssertEqual(m.used, 150)
    }

    func testCanUseGoogleFalseOverCap() {
        let m = meter { "2026-7" }
        m.record(489_950)
        XCTAssertTrue(m.canUseGoogle(adding: 50))    // 490_000 <= cap
        XCTAssertFalse(m.canUseGoogle(adding: 51))   // 490_001 > cap
    }

    func testMonthRolloverResets() {
        final class MonthBox: @unchecked Sendable { var value: String; init(_ v: String) { value = v } }
        let box = MonthBox("2026-7")
        let m = UsageMeter(store: FakeStore(), month: { box.value })
        m.record(1000); m.markNotified()
        XCTAssertEqual(m.used, 1000)
        XCTAssertTrue(m.hasNotified)
        box.value = "2026-8"
        XCTAssertEqual(m.used, 0)           // rolled over
        XCTAssertFalse(m.hasNotified)       // re-armed
    }

    func testNotifiedFlagWithinMonth() {
        let m = meter { "2026-7" }
        XCTAssertFalse(m.hasNotified)
        m.markNotified()
        XCTAssertTrue(m.hasNotified)
    }
}

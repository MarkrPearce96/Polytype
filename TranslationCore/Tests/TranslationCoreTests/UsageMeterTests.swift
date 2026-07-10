import XCTest
@testable import TranslationCore

private final class FakeStore: UsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ints: [String: Int] = [:]; private var strings: [String: String] = [:]
    private var bools: [String: Bool] = [:]; private var doubles: [String: Double] = [:]
    func int(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; return ints[k] ?? 0 }
    func setInt(_ v: Int, _ k: String) { lock.lock(); ints[k] = v; lock.unlock() }
    func string(_ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return strings[k] }
    func setString(_ v: String?, _ k: String) { lock.lock(); strings[k] = v; lock.unlock() }
    func bool(_ k: String) -> Bool { lock.lock(); defer { lock.unlock() }; return bools[k] ?? false }
    func setBool(_ v: Bool, _ k: String) { lock.lock(); bools[k] = v; lock.unlock() }
    func double(_ k: String) -> Double { lock.lock(); defer { lock.unlock() }; return doubles[k] ?? 0 }
    func setDouble(_ v: Double, _ k: String) { lock.lock(); doubles[k] = v; lock.unlock() }
}

private final class Clock: @unchecked Sendable { var date: Date; init(_ d: Date) { date = d } }

final class UsageMeterTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        return Calendar(identifier: .gregorian).date(from: c)!
    }
    private func meter(_ clock: Clock) -> UsageMeter { UsageMeter(store: FakeStore(), now: { clock.date }) }

    func testRecordAccumulatesAndCapBoundary() {
        let m = meter(Clock(date(2026, 7, 10)))
        m.record(100); m.record(50)
        XCTAssertEqual(m.used, 150)
        m.record(489_800)                             // 489_950
        XCTAssertTrue(m.canUseGoogle(adding: 50))     // 490_000 <= cap
        XCTAssertFalse(m.canUseGoogle(adding: 51))    // 490_001 > cap
    }

    func testCalibrateSetsUsedAndResetAndClearsNotified() {
        let m = meter(Clock(date(2026, 7, 10)))
        m.markNotified()
        m.calibrate(used: 42_000, nextReset: date(2026, 8, 3))
        XCTAssertEqual(m.used, 42_000)
        XCTAssertEqual(m.nextResetDate, date(2026, 8, 3))
        XCTAssertFalse(m.hasNotified)
    }

    func testNoResetBeforeDate() {
        let clock = Clock(date(2026, 7, 10))
        let m = meter(clock)
        m.calibrate(used: 1000, nextReset: date(2026, 8, 3)); m.markNotified()
        clock.date = date(2026, 8, 2)
        XCTAssertEqual(m.used, 1000)
        XCTAssertTrue(m.hasNotified)
    }

    func testResetAtDateAdvancesOneMonth() {
        let clock = Clock(date(2026, 7, 10))
        let m = meter(clock)
        m.calibrate(used: 1000, nextReset: date(2026, 8, 3)); m.markNotified()
        clock.date = date(2026, 8, 3)
        XCTAssertEqual(m.used, 0)
        XCTAssertFalse(m.hasNotified)
        XCTAssertEqual(m.nextResetDate, date(2026, 9, 3))
    }

    func testLongGapAdvancesToFirstFutureBoundary() {
        let clock = Clock(date(2026, 7, 10))
        let m = meter(clock)
        m.calibrate(used: 1000, nextReset: date(2026, 8, 3))
        clock.date = date(2026, 11, 20)
        XCTAssertEqual(m.used, 0)
        XCTAssertEqual(m.nextResetDate, date(2026, 12, 3))
    }

    func testUncalibratedDefaultIsFirstOfNextMonth() {
        let m = meter(Clock(date(2026, 7, 10)))
        XCTAssertEqual(m.nextResetDate, date(2026, 8, 1))
    }
}

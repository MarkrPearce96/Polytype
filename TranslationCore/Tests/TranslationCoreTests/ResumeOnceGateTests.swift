import XCTest
@testable import TranslationCore

/// Covers the exactly-once, never-hangs coordination primitive that
/// `AppleEngine`'s `SessionProvider` uses to make its session timeout hang-proof:
/// whichever of a producer or a timeout resumes the gate first wins, and the loser
/// (including a producer that fires late, after a timeout already won) is a no-op.
final class ResumeOnceGateTests: XCTestCase {
    private struct Boom: Error, Equatable {}

    func testProducerBeforeTimeoutReturnsTheValue() async throws {
        let gate = ResumeOnceGate<String>()
        await gate.armTimeout(after: .milliseconds(50)) { Boom() }

        // Producer resolves immediately, long before the 50ms timeout would fire.
        await gate.resume(returning: "hello")

        let value = try await gate.wait()
        XCTAssertEqual(value, "hello")
    }

    func testTimeoutBeforeProducerThrowsAndDoesNotHang() async {
        let gate = ResumeOnceGate<String>()
        await gate.armTimeout(after: .milliseconds(50)) { Boom() }

        // No producer ever resumes the gate; only the timeout can unblock `wait()`.
        // If this hung, the test itself would time out/fail rather than passing.
        do {
            _ = try await gate.wait()
            XCTFail("expected the timeout error")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }
    }

    func testLateProducerAfterTimeoutIsHarmlessNoOp() async throws {
        let gate = ResumeOnceGate<String>()
        await gate.armTimeout(after: .milliseconds(50)) { Boom() }

        do {
            _ = try await gate.wait()
            XCTFail("expected the timeout error")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }

        // A producer that fires after the timeout already won must not crash and
        // must not overwrite the already-delivered result.
        await gate.resume(returning: "too-late")

        do {
            _ = try await gate.wait()
            XCTFail("expected the original timeout error to still be in effect")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }
    }
}

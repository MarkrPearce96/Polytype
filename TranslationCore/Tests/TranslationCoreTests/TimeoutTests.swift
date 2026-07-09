import XCTest
@testable import TranslationCore

/// Covers the generic cancellable-operation timeout race that `AppleEngine.translate`
/// uses to bound its call into `TranslationSession.translate`: whichever of
/// `operation` or the timeout finishes first wins, and — because `operation` here is
/// cancellation-aware — the loser actually unwinds rather than lingering.
final class WithTimeoutTests: XCTestCase {
    private struct Boom: Error, Equatable {}

    func testFastOperationReturnsItsValue() async throws {
        let value = try await withTimeout(seconds: .milliseconds(200), onTimeout: { Boom() }) {
            "hello"
        }
        XCTAssertEqual(value, "hello")
    }

    func testSlowOperationThrowsTimeoutRatherThanHanging() async {
        // `operation` sleeps far longer than the timeout, but `Task.sleep` is itself
        // cancellation-aware: once the timeout wins and `cancelAll()` runs, this child
        // task unwinds immediately instead of actually waiting out the full duration.
        // If it didn't, this test would take ~60s (or hang) instead of ~50ms.
        do {
            _ = try await withTimeout(seconds: .milliseconds(50), onTimeout: { Boom() }) {
                try await Task.sleep(for: .seconds(60))
                return "too-slow"
            }
            XCTFail("expected the timeout error")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }
    }
}

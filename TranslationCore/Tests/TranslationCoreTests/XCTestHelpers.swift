import XCTest

/// Async throwing assertion helper, shared across the engine test suites.
func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> some Any,
                              _ handler: (Error) -> Void) async {
    do { _ = try await expression(); XCTFail("expected error") }
    catch { handler(error) }
}

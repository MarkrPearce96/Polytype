import XCTest
@testable import TranslationCore

final class AppleEngineTests: XCTestCase {
    func testAutoSourceThrows() async {
        // AppleEngine's real implementation is @available(macOS 15.0, *), so its
        // instantiation must be guarded. On older systems the test is a no-op.
        // "auto" must be rejected before any session work.
        guard #available(macOS 15.0, *) else { return }
        let engine = AppleEngine()
        await XCTAssertThrowsErrorAsync(try await engine.translate("你好", from: "auto", to: "en")) { error in
            XCTAssertTrue(error is TranslationError)
        }
    }
}

import XCTest
@testable import TranslationCore

final class HTTPClientTests: XCTestCase {
    func testSpaceEncodesToPercent20() {
        let encoded = FormURLEncoding.encode(["q": "a b"])
        XCTAssertEqual(encoded, "q=a%20b")
    }

    func testReservedCharAmpersandEncodesToPercent26() {
        let encoded = FormURLEncoding.encode(["q": "a&b"])
        XCTAssertEqual(encoded, "q=a%26b")
    }

    func testAccentedCharEEncodesToUTF8Percent() {
        let encoded = FormURLEncoding.encode(["q": "café"])
        XCTAssertTrue(encoded.contains("%C3%A9"))
        XCTAssertEqual(encoded, "q=caf%C3%A9")
    }

    func testCJKCharEncodesToUTF8Percent() {
        let encoded = FormURLEncoding.encode(["q": "你"])
        XCTAssertEqual(encoded, "q=%E4%BD%A0")
    }

    func testUnreservedCharsPassThroughUnchanged() {
        let encoded = FormURLEncoding.encode(["q": "abc-._~"])
        XCTAssertEqual(encoded, "q=abc-._~")
    }
}

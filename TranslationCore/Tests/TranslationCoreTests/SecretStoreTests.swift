import XCTest
@testable import TranslationCore

final class SecretStoreTests: XCTestCase {
    func testSetGetRoundTrip() {
        let store = InMemorySecretStore()
        XCTAssertNil(store.get(googleKeyName))
        store.set("abc123", for: googleKeyName)
        XCTAssertEqual(store.get(googleKeyName), "abc123")
    }

    func testSetNilDeletes() {
        let store = InMemorySecretStore()
        store.set("abc123", for: googleKeyName)
        store.set(nil, for: googleKeyName)
        XCTAssertNil(store.get(googleKeyName))
    }
}

import XCTest
@testable import TranslationCore

final class SecretStoreTests: XCTestCase {
    func testSetGetRoundTrip() {
        let store = InMemorySecretStore()
        XCTAssertNil(store.get(deepLKeyName))
        store.set("abc123", for: deepLKeyName)
        XCTAssertEqual(store.get(deepLKeyName), "abc123")
    }

    func testSetNilDeletes() {
        let store = InMemorySecretStore()
        store.set("abc123", for: deepLKeyName)
        store.set(nil, for: deepLKeyName)
        XCTAssertNil(store.get(deepLKeyName))
    }
}

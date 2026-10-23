import XCTest
@testable import PerchCore
final class MootCredentialTests: XCTestCase {
    func testUniqueTemporaryCredentialRoundTrip() throws {
        let store = MootCredentialStore(), ref = "test-" + UUID().uuidString
        defer { try? store.remove(ref: ref) }
        try store.put(ref: ref, secret: Data("test-not-a-provider-key".utf8))
        XCTAssertEqual(try store.read(ref: ref), Data("test-not-a-provider-key".utf8))
    }
}

import XCTest
@testable import ConvoLab

final class KeychainStoreTests: XCTestCase {
    @MainActor
    func testGenericPasswordRoundTrip() throws {
        let store = KeychainStore()
        let account = "test-\(UUID().uuidString)"
        defer { try? store.remove(account: account) }

        try store.save("token", account: account)

        XCTAssertEqual(try store.read(account: account), "token")
    }
}

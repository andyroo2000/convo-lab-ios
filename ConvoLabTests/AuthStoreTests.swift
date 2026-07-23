import Foundation
import XCTest
@testable import ConvoLab

final class AuthStoreTests: XCTestCase {
    @MainActor
    func testOfflineRestoreKeepsTokenAndUsesCachedUser() async throws {
        let user = CurrentUser(
            id: "01J00000000000000000000000",
            name: "Andrew",
            email: "andrew@example.com",
            emailVerifiedAt: nil
        )
        let credentials = MemoryCredentialStore(values: [
            "learning-os-mobile-token": "valid-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(user),
                encoding: .utf8
            )!,
        ])
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let store = AuthStore(api: client, keychain: credentials)

        await store.restore()

        guard case let .signedIn(restoredUser) = store.state else {
            return XCTFail("Expected cached offline user to remain signed in")
        }
        XCTAssertEqual(restoredUser.email, user.email)
        XCTAssertEqual(client.accessToken, "valid-token")
        XCTAssertEqual(try credentials.read(account: "learning-os-mobile-token"), "valid-token")
    }

    @MainActor
    func testUnauthorizedRestoreClearsCachedCredentials() async throws {
        let credentials = MemoryCredentialStore(values: [
            "learning-os-mobile-token": "expired-token",
            "learning-os-current-user": "{}",
        ])
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"message":"Unauthenticated."}"#.utf8))
        }
        let store = AuthStore(api: client, keychain: credentials)

        await store.restore()

        guard case .signedOut = store.state else {
            return XCTFail("Expected unauthorized token to sign out")
        }
        XCTAssertNil(client.accessToken)
        XCTAssertNil(try credentials.read(account: "learning-os-mobile-token"))
        XCTAssertNil(try credentials.read(account: "learning-os-current-user"))
    }

    @MainActor
    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }
}

@MainActor
private final class MemoryCredentialStore: CredentialStore {
    private var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func save(_ value: String, account: String) throws {
        values[account] = value
    }

    func read(account: String) throws -> String? {
        values[account]
    }

    func remove(account: String) throws {
        values[account] = nil
    }
}

import Foundation
import XCTest
@testable import ConvoLab

final class AuthStoreTests: XCTestCase {
    @MainActor
    func testOfflineRestoreKeepsTokenAndUsesCachedUser() async throws {
        let user = CurrentUser(
            id: 1,
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
    func testRegistrationUsesInviteGatedConvoLabEndpointAndStoresToken() async throws {
        let credentials = MemoryCredentialStore()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/convolab/auth/register")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try requestBody(request)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: String]
            )
            XCTAssertEqual(payload["name"], "Andrew")
            XCTAssertEqual(payload["email"], "andrew@example.com")
            XCTAssertEqual(payload["inviteCode"], "INVITE1")
            XCTAssertNotNil(payload["device_name"])
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"{"data":{"user":{"id":1,"name":"Andrew","email":"andrew@example.com","email_verified_at":null},"token":"new-token"}}"#.utf8
                )
            )
        }
        let store = AuthStore(api: client, keychain: credentials)

        await store.register(
            name: "Andrew",
            email: "andrew@example.com",
            password: "password123",
            inviteCode: "INVITE1"
        )

        guard case let .signedIn(user) = store.state else {
            return XCTFail("Expected registration to sign in")
        }
        XCTAssertEqual(user.email, "andrew@example.com")
        XCTAssertEqual(client.accessToken, "new-token")
        XCTAssertEqual(
            try credentials.read(account: "learning-os-mobile-token"),
            "new-token"
        )
    }

    @MainActor
    func testProfileResponseCannotSignBackInAfterLogout() async throws {
        let originalUser = CurrentUser(
            id: 1,
            name: "Andrew",
            email: "andrew@example.com",
            emailVerifiedAt: nil
        )
        let credentials = MemoryCredentialStore(values: [
            "learning-os-mobile-token": "valid-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(originalUser),
                encoding: .utf8
            )!,
        ])
        let deferredProfile = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/me", "GET"):
                completion(.success(Self.response(data: Data(
                    #"{"data":{"id":1,"name":"Andrew","email":"andrew@example.com","email_verified_at":null}}"#.utf8
                ))))
            case ("/api/me", "PUT"):
                deferredProfile.hold(completion)
            case ("/api/auth/tokens/current", "DELETE"):
                completion(.success(Self.response(statusCode: 204)))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                completion(.failure(URLError(.badURL)))
            }
        }
        let store = AuthStore(api: client, keychain: credentials)
        await store.restore()

        let update = Task {
            await store.updateProfile(name: "Updated", email: "updated@example.com")
        }
        await waitUntil { deferredProfile.hasPendingResponse }
        await store.logout()
        deferredProfile.succeed(with: Self.response(data: Data(
            #"{"data":{"id":1,"name":"Updated","email":"updated@example.com","email_verified_at":null}}"#.utf8
        )))
        _ = await update.value

        guard case .signedOut = store.state else {
            return XCTFail("A stale profile response must not restore the signed-in state")
        }
        XCTAssertNil(client.accessToken)
        XCTAssertNil(try credentials.read(account: "learning-os-mobile-token"))
        XCTAssertNil(try credentials.read(account: "learning-os-current-user"))
    }

    @MainActor
    func testProfileResponseCannotSignBackInAfterAccountDeletion() async throws {
        let originalUser = CurrentUser(
            id: 1,
            name: "Andrew",
            email: "andrew@example.com",
            emailVerifiedAt: nil
        )
        let credentials = MemoryCredentialStore(values: [
            "learning-os-mobile-token": "valid-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(originalUser),
                encoding: .utf8
            )!,
        ])
        let deferredProfile = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/me", "GET"):
                completion(.success(Self.response(data: Data(
                    #"{"data":{"id":1,"name":"Andrew","email":"andrew@example.com","email_verified_at":null}}"#.utf8
                ))))
            case ("/api/me", "PUT"):
                deferredProfile.hold(completion)
            case ("/api/me", "DELETE"):
                completion(.success(Self.response(statusCode: 204)))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                completion(.failure(URLError(.badURL)))
            }
        }
        let store = AuthStore(api: client, keychain: credentials)
        await store.restore()

        let update = Task {
            await store.updateProfile(name: "Updated", email: "updated@example.com")
        }
        await waitUntil { deferredProfile.hasPendingResponse }
        let deleted = await store.deleteAccount(currentPassword: "password")
        XCTAssertTrue(deleted)
        deferredProfile.succeed(with: Self.response(data: Data(
            #"{"data":{"id":1,"name":"Updated","email":"updated@example.com","email_verified_at":null}}"#.utf8
        )))
        _ = await update.value

        guard case .signedOut = store.state else {
            return XCTFail("A stale profile response must not revive a deleted account")
        }
        XCTAssertNil(client.accessToken)
        XCTAssertNil(try credentials.read(account: "learning-os-mobile-token"))
        XCTAssertNil(try credentials.read(account: "learning-os-current-user"))
    }

    @MainActor
    func testPasswordErrorCannotLeakOntoLoginAfterLogout() async throws {
        let originalUser = CurrentUser(
            id: 1,
            name: "Andrew",
            email: "andrew@example.com",
            emailVerifiedAt: nil
        )
        let credentials = MemoryCredentialStore(values: [
            "learning-os-mobile-token": "valid-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(originalUser),
                encoding: .utf8
            )!,
        ])
        let deferredPassword = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/me", "GET"):
                completion(.success(Self.response(data: Data(
                    #"{"data":{"id":1,"name":"Andrew","email":"andrew@example.com","email_verified_at":null}}"#.utf8
                ))))
            case ("/api/me/password", "PUT"):
                deferredPassword.hold(completion)
            case ("/api/auth/tokens/current", "DELETE"):
                completion(.success(Self.response(statusCode: 204)))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                completion(.failure(URLError(.badURL)))
            }
        }
        let store = AuthStore(api: client, keychain: credentials)
        await store.restore()

        let update = Task {
            await store.updatePassword(
                currentPassword: "old-password",
                password: "new-password",
                passwordConfirmation: "new-password"
            )
        }
        await waitUntil { deferredPassword.hasPendingResponse }
        await store.logout()
        deferredPassword.succeed(with: Self.response(
            statusCode: 422,
            data: Data(#"{"message":"The current password is incorrect."}"#.utf8)
        ))
        _ = await update.value

        guard case .signedOut = store.state else {
            return XCTFail("Expected logout to remain authoritative")
        }
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isWorking)
    }

    @MainActor
    func testStaleAccountDeletionCannotClearNewRegistration() async throws {
        let originalUser = CurrentUser(
            id: 1,
            name: "Andrew",
            email: "andrew@example.com",
            emailVerifiedAt: nil
        )
        let credentials = MemoryCredentialStore(values: [
            "learning-os-mobile-token": "old-token",
            "learning-os-current-user": String(
                data: try JSONEncoder().encode(originalUser),
                encoding: .utf8
            )!,
        ])
        let deferredDeletion = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/me", "GET"):
                completion(.success(Self.response(data: Data(
                    #"{"data":{"id":1,"name":"Andrew","email":"andrew@example.com","email_verified_at":null}}"#.utf8
                ))))
            case ("/api/me", "DELETE"):
                deferredDeletion.hold(completion)
            case ("/api/auth/tokens/current", "DELETE"):
                completion(.success(Self.response(statusCode: 204)))
            case ("/api/convolab/auth/register", "POST"):
                completion(.success(Self.response(statusCode: 201, data: Data(
                    #"{"data":{"user":{"id":2,"name":"New User","email":"new@example.com","email_verified_at":null},"token":"new-token"}}"#.utf8
                ))))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                completion(.failure(URLError(.badURL)))
            }
        }
        let store = AuthStore(api: client, keychain: credentials)
        await store.restore()
        var deletionWasConfirmed = false

        let deletion = Task {
            await store.deleteAccount(
                currentPassword: "password",
                onConfirmed: { deletionWasConfirmed = true }
            )
        }
        await waitUntil { deferredDeletion.hasPendingResponse }
        await store.logout()
        await store.register(
            name: "New User",
            email: "new@example.com",
            password: "password123",
            inviteCode: "INVITE1"
        )
        deferredDeletion.succeed(with: Self.response(statusCode: 204))
        let deleted = await deletion.value

        XCTAssertFalse(deleted)
        XCTAssertTrue(deletionWasConfirmed)
        guard case let .signedIn(user) = store.state else {
            return XCTFail("The new registration must remain signed in")
        }
        XCTAssertEqual(user.id, 2)
        XCTAssertEqual(client.accessToken, "new-token")
        XCTAssertEqual(
            try credentials.read(account: "learning-os-mobile-token"),
            "new-token"
        )
    }

    @MainActor
    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func makeDeferredClient(
        handler: @escaping MockURLProtocol.DeferredHandler
    ) -> APIClient {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func response(
        statusCode: Int = 200,
        data: Data = Data()
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: URL(string: "https://learning-os.example")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
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

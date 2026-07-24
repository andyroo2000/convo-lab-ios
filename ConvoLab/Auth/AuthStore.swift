import Foundation
import UIKit

@Observable
final class AuthStore {
    enum State {
        case restoring
        case signedOut
        case signedIn(CurrentUser)
    }

    private(set) var state: State = .restoring
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    private let api: APIClient
    private let keychain: any CredentialStore
    private let tokenAccount = "learning-os-mobile-token"
    private let userAccount = "learning-os-current-user"

    init(api: APIClient, keychain: any CredentialStore = KeychainStore()) {
        self.api = api
        self.keychain = keychain
    }

    func restore() async {
        do {
            guard let token = try keychain.read(account: tokenAccount) else {
                state = .signedOut
                return
            }
            api.setAccessToken(token)
            let envelope: APIEnvelope<CurrentUser> = try await api.request("/api/me")
            try cacheUser(envelope.data)
            state = .signedIn(envelope.data)
        } catch APIClientError.rejected(status: 401, message: _) {
            clearCredentials()
            state = .signedOut
        } catch {
            // A network failure does not invalidate a bearer token. Use the last verified
            // profile so a cold launch can still enter the local-first app while offline.
            if let cachedUser = try? cachedUser() {
                state = .signedIn(cachedUser)
            } else {
                errorMessage = "Your account could not be verified while offline."
                state = .signedOut
            }
        }
    }

    func login(email: String, password: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let deviceName = UIDevice.current.name
            let response: MobileTokenResponse = try await api.request(
                "/api/auth/tokens",
                method: "POST",
                body: LoginRequest(email: email, password: password, deviceName: deviceName)
            )
            try keychain.save(response.data.token, account: tokenAccount)
            api.setAccessToken(response.data.token)
            let user: APIEnvelope<CurrentUser> = try await api.request("/api/me")
            try cacheUser(user.data)
            state = .signedIn(user.data)
        } catch {
            errorMessage = error.localizedDescription
            state = .signedOut
        }
    }

    func requestPasswordReset(email: String) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let _: JSONValue = try await api.request(
                "/api/auth/password/forgot",
                method: "POST",
                body: PasswordResetRequest(email: email)
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func logout() async {
        if api.accessToken != nil {
            let _: IgnoredResponse = (try? await api.request(
                "/api/auth/tokens/current",
                method: "DELETE"
            )) ?? IgnoredResponse()
        }
        clearCredentials()
        state = .signedOut
    }

    private func cacheUser(_ user: CurrentUser) throws {
        let data = try JSONEncoder().encode(user)
        guard let value = String(data: data, encoding: .utf8) else {
            return
        }
        try keychain.save(value, account: userAccount)
    }

    private func cachedUser() throws -> CurrentUser? {
        guard
            let value = try keychain.read(account: userAccount),
            let data = value.data(using: .utf8)
        else {
            return nil
        }
        return try JSONDecoder().decode(CurrentUser.self, from: data)
    }

    private func clearCredentials() {
        api.setAccessToken(nil)
        try? keychain.remove(account: tokenAccount)
        try? keychain.remove(account: userAccount)
    }
}

struct IgnoredResponse: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}

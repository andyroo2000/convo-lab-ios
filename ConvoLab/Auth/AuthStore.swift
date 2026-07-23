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
    private let keychain: KeychainStore
    private let tokenAccount = "learning-os-mobile-token"

    init(api: APIClient, keychain: KeychainStore = KeychainStore()) {
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
            state = .signedIn(envelope.data)
        } catch {
            api.setAccessToken(nil)
            try? keychain.remove(account: tokenAccount)
            state = .signedOut
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
            let _: IgnoredResponse? = try? await api.request(
                "/api/auth/tokens/current",
                method: "DELETE"
            )
        }
        api.setAccessToken(nil)
        try? keychain.remove(account: tokenAccount)
        state = .signedOut
    }
}

struct IgnoredResponse: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}

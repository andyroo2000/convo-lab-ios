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
    private var authenticationGeneration = 0
    private var workingOperationID: UUID?

    private struct CredentialSnapshot {
        let token: String?
        let cachedUser: String?
        let apiToken: String?
        let state: State
    }

    init(api: APIClient, keychain: any CredentialStore = KeychainStore()) {
        self.api = api
        self.keychain = keychain
        restoreCachedSession()
    }

    func restore() async {
        let generation = authenticationGeneration
        guard restoreCachedSession() else { return }
        do {
            let envelope: APIEnvelope<CurrentUser> = try await api.request("/api/me")
            guard authenticationGeneration == generation else { return }
            try cacheUser(envelope.data)
            state = .signedIn(envelope.data)
        } catch APIClientError.rejected(status: 401, message: _) {
            guard authenticationGeneration == generation else { return }
            clearCredentials()
            state = .signedOut
        } catch {
            guard authenticationGeneration == generation else { return }
            // A network failure does not invalidate a bearer token. Use the last verified
            // profile so a cold launch can still enter the local-first app while offline.
            if case .signedIn = state {
                // The cached profile was published before verification began.
            } else if let cachedUser = try? cachedUser() {
                state = .signedIn(cachedUser)
            } else {
                errorMessage = "Your account could not be verified while offline."
                state = .signedOut
            }
        }
    }

    func login(email: String, password: String) async {
        let operation = beginAuthenticationOperation()
        errorMessage = nil
        defer { finishWorking(operation.id) }

        do {
            let snapshot = try credentialSnapshot()
            let deviceName = UIDevice.current.name
            let response: MobileTokenResponse = try await api.request(
                "/api/auth/tokens",
                method: "POST",
                body: LoginRequest(email: email, password: password, deviceName: deviceName)
            )
            guard authenticationGeneration == operation.generation else { return }
            let user: APIEnvelope<CurrentUser> = try await api.request(
                "/api/me",
                authorizationToken: response.data.token
            )
            guard authenticationGeneration == operation.generation else { return }
            try commitCredentials(
                token: response.data.token,
                user: user.data,
                restoring: snapshot
            )
            state = .signedIn(user.data)
        } catch {
            guard authenticationGeneration == operation.generation else { return }
            errorMessage = error.localizedDescription
            if case .signedIn = state {
                // A failed reauthentication attempt must not evict the current account.
            } else {
                state = .signedOut
            }
        }
    }

    func register(
        name: String,
        email: String,
        password: String,
        inviteCode: String
    ) async {
        let operation = beginAuthenticationOperation()
        errorMessage = nil
        defer { finishWorking(operation.id) }

        do {
            let snapshot = try credentialSnapshot()
            let response: RegistrationResponse = try await api.request(
                "/api/convolab/auth/register",
                method: "POST",
                body: RegistrationRequest(
                    name: name,
                    email: email,
                    password: password,
                    inviteCode: inviteCode,
                    deviceName: UIDevice.current.name
                )
            )
            guard authenticationGeneration == operation.generation else { return }
            try commitCredentials(
                token: response.data.token,
                user: response.data.user,
                restoring: snapshot
            )
            state = .signedIn(response.data.user)
        } catch {
            guard authenticationGeneration == operation.generation else { return }
            errorMessage = error.localizedDescription
            if case .signedIn = state {
                // A failed registration attempt must not evict the current account.
            } else {
                state = .signedOut
            }
        }
    }

    func updateProfile(name: String, email: String) async -> Bool {
        let generation = authenticationGeneration
        let operationID = UUID()
        workingOperationID = operationID
        isWorking = true
        errorMessage = nil
        defer { finishWorking(operationID) }
        do {
            let response: APIEnvelope<CurrentUser> = try await api.request(
                "/api/me",
                method: "PUT",
                body: UpdateProfileRequest(name: name, email: email)
            )
            guard authenticationGeneration == generation else { return false }
            try cacheUser(response.data)
            state = .signedIn(response.data)
            return true
        } catch {
            guard authenticationGeneration == generation else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updatePassword(
        currentPassword: String,
        password: String,
        passwordConfirmation: String
    ) async -> Bool {
        let generation = authenticationGeneration
        let operationID = UUID()
        workingOperationID = operationID
        isWorking = true
        errorMessage = nil
        defer { finishWorking(operationID) }
        do {
            try await api.request(
                "/api/me/password",
                method: "PUT",
                body: UpdatePasswordRequest(
                    currentPassword: currentPassword,
                    password: password,
                    passwordConfirmation: passwordConfirmation
                )
            )
            guard authenticationGeneration == generation else { return false }
            return true
        } catch {
            guard authenticationGeneration == generation else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteAccount(
        currentPassword: String,
        onConfirmed: () -> Void = {}
    ) async -> Bool {
        let generation = authenticationGeneration
        let operationID = UUID()
        workingOperationID = operationID
        isWorking = true
        errorMessage = nil
        defer { finishWorking(operationID) }
        do {
            try await api.request(
                "/api/me",
                method: "DELETE",
                body: DeleteAccountRequest(currentPassword: currentPassword)
            )
            // A 2xx response confirms that the original account is gone, even if a
            // newer auth operation now owns the session. Persist its cleanup before
            // either returning for that stale response or clearing credentials.
            onConfirmed()
            guard authenticationGeneration == generation else { return false }
            authenticationGeneration += 1
            errorMessage = nil
            clearCredentials()
            state = .signedOut
            return true
        } catch {
            guard authenticationGeneration == generation else { return false }
            errorMessage = error.localizedDescription
            return false
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
        authenticationGeneration += 1
        workingOperationID = nil
        isWorking = false
        errorMessage = nil
        if api.accessToken != nil {
            try? await api.request(
                "/api/auth/tokens/current",
                method: "DELETE"
            )
        }
        clearCredentials()
        state = .signedOut
    }

    func discardCachedSession() {
        authenticationGeneration += 1
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

    private func beginAuthenticationOperation() -> (generation: Int, id: UUID) {
        authenticationGeneration += 1
        let operationID = UUID()
        workingOperationID = operationID
        isWorking = true
        return (authenticationGeneration, operationID)
    }

    private func credentialSnapshot() throws -> CredentialSnapshot {
        try CredentialSnapshot(
            token: keychain.read(account: tokenAccount),
            cachedUser: keychain.read(account: userAccount),
            apiToken: api.accessToken,
            state: state
        )
    }

    private func commitCredentials(
        token: String,
        user: CurrentUser,
        restoring snapshot: CredentialSnapshot
    ) throws {
        do {
            // Commit the profile first. If that write fails, the newly issued token
            // has never entered persistent storage or the shared API client.
            try cacheUser(user)
            try keychain.save(token, account: tokenAccount)
        } catch {
            restoreCredentials(snapshot)
            throw error
        }
        api.setAccessToken(token)
    }

    private func restoreCredentials(_ snapshot: CredentialSnapshot) {
        restore(snapshot.cachedUser, account: userAccount)
        restore(snapshot.token, account: tokenAccount)
        api.setAccessToken(snapshot.apiToken)
        state = snapshot.state
    }

    private func restore(_ value: String?, account: String) {
        if let value {
            try? keychain.save(value, account: account)
        } else {
            try? keychain.remove(account: account)
        }
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

    @discardableResult
    private func restoreCachedSession() -> Bool {
        do {
            guard let token = try keychain.read(account: tokenAccount) else {
                api.setAccessToken(nil)
                state = .signedOut
                return false
            }
            api.setAccessToken(token)
            if let user = try? cachedUser() {
                state = .signedIn(user)
            } else {
                // A token from an older app build may predate profile caching. Only
                // that one-time migration needs the blocking verification state.
                state = .restoring
            }
            return true
        } catch {
            api.setAccessToken(nil)
            errorMessage = "Your saved account could not be opened."
            state = .signedOut
            return false
        }
    }

    private func clearCredentials() {
        api.setAccessToken(nil)
        try? keychain.remove(account: tokenAccount)
        try? keychain.remove(account: userAccount)
    }

    private func finishWorking(_ operationID: UUID) {
        guard workingOperationID == operationID else { return }
        workingOperationID = nil
        isWorking = false
    }
}

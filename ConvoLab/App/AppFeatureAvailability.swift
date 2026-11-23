import SwiftUI

nonisolated struct AppFeatureFlags: Codable, Equatable, Sendable {
    let flashcardsEnabled: Bool
    let readingsEnabled: Bool
    let studyTimeEnabled: Bool

    static let journalOnly = Self(flashcardsEnabled: false, readingsEnabled: false, studyTimeEnabled: false)

    var modes: Set<AppMode> {
        var result: Set<AppMode> = [.journal, .settings]
        if flashcardsEnabled { result.formUnion([.study, .cards]) }
        if readingsEnabled { result.insert(.readings) }
        if studyTimeEnabled { result.insert(.time) }
        return result
    }
}

@Observable
final class AppFeatureAvailability {
    private(set) var flags: AppFeatureFlags
    private let cacheKey: String?
    private let defaults: UserDefaults
    private var revision = 0

    init(flags: AppFeatureFlags = .journalOnly, cacheKey: String? = nil, defaults: UserDefaults = .standard) {
        self.cacheKey = cacheKey
        self.defaults = defaults
        self.flags = flags
        if let cacheKey, let data = defaults.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(AppFeatureFlags.self, from: data) {
            self.flags = cached
        }
    }

    func refresh(api: APIClient) async {
        let token = api.accessToken
        revision += 1
        let requestRevision = revision
        do {
            let next: AppFeatureFlags = try await api.request("/api/convolab/feature-availability")
            guard accepts(api: api, token: token, revision: requestRevision) else { return }
            apply(next)
        } catch {
            guard accepts(api: api, token: token, revision: requestRevision) else { return }
            if case let APIClientError.rejected(status, _) = error, [401, 403, 404].contains(status) {
                apply(.journalOnly)
            }
            // Transport failures keep this account's cached visibility for offline study.
        }
    }

    private func accepts(api: APIClient, token: String?, revision: Int) -> Bool {
        !Task.isCancelled && api.accessToken == token && self.revision == revision
    }

    private func apply(_ next: AppFeatureFlags) {
        flags = next
        if let cacheKey, let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: cacheKey)
        }
    }
}

private struct AvailableAppModesKey: EnvironmentKey {
    // Standalone previews and test fixtures retain their explicit destinations.
    static let defaultValue = Set(AppMode.allCases)
}

extension EnvironmentValues {
    var availableAppModes: Set<AppMode> {
        get { self[AvailableAppModesKey.self] }
        set { self[AvailableAppModesKey.self] = newValue }
    }
}

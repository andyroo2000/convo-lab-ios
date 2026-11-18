import SwiftUI

nonisolated struct AppFeatureFlags: Decodable, Equatable, Sendable {
    let flashcardsEnabled: Bool
    let readingsEnabled: Bool
    let studyTimeEnabled: Bool

    static let journalOnly = Self(flashcardsEnabled: false, readingsEnabled: false, studyTimeEnabled: false)

    var modes: Set<AppMode> {
        var result: Set<AppMode> = [.journal, .settings]
        if flashcardsEnabled { result.formUnion([.study, .cards, .dailyAudio]) }
        if readingsEnabled { result.insert(.readings) }
        if studyTimeEnabled { result.insert(.time) }
        return result
    }
}

@Observable
final class AppFeatureAvailability {
    private(set) var flags: AppFeatureFlags

    init(flags: AppFeatureFlags = .journalOnly) { self.flags = flags }

    func refresh(api: APIClient) async {
        let token = api.accessToken
        do {
            let next: AppFeatureFlags = try await api.request("/api/convolab/feature-availability")
            guard !Task.isCancelled, api.accessToken == token else { return }
            flags = next
        } catch {
            // Keep this session's last known visibility while offline. New sessions start Journal-only.
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

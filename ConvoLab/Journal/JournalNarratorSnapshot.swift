import Foundation

/// Display-only metadata in the account's Journal directory. Playback still requires server validation.
actor JournalNarratorSnapshot {
    nonisolated struct Value: Codable, Sendable {
        let analysisID: String
        let revision: Int
        let voices: [JournalVoice]
        let selected: String
    }

    static let shared = JournalNarratorSnapshot()

    func read(_ url: URL?) -> Value? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func write(_ value: Value, to url: URL?) {
        guard let url else { return }
        // The owner directory is created and removed by Journal storage; never recreate it after sign-out.
        try? JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

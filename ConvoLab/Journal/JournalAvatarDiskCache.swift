import CryptoKit
import Foundation

/// Public catalog artwork only; never stores credentials or learner media.
actor JournalAvatarDiskCache {
    nonisolated struct Entry: Codable, Sendable {
        let data: Data
        let savedAt: Date
    }

    private let directory: URL
    private let limit = 64

    init(directory: URL) { self.directory = directory }

    func read(_ url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: file(url)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func write(_ entry: Entry, for url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: file(url), options: .atomic)
            trim()
        } catch { /* A full or unavailable cache must not prevent displaying an avatar. */ }
    }

    private func file(_ url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    // Evict oldest-written entries; this small catalog cache is not an LRU.
    private func trim() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

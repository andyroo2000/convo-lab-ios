import Foundation

struct JournalSyncCheckpoint: Codable {
    var pending: JournalDraft?
    var rejection: Int?
}

@MainActor
struct JournalSyncStorage {
    let directory: URL

    init(drafts: JournalDraftStorage) { directory = drafts.directory.appending(path: "sync") }

    func load(_ id: String) throws -> JournalSyncCheckpoint {
        let url = try file(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return JournalSyncCheckpoint() }
        return try JSONDecoder().decode(JournalSyncCheckpoint.self, from: Data(contentsOf: url))
    }

    func save(_ checkpoint: JournalSyncCheckpoint, id: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: file(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove(_ id: String) throws {
        let url = try file(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func file(_ id: String) throws -> URL {
        guard ClientIdentifier.isULID(id) else { throw CocoaError(.fileReadInvalidFileName) }
        return directory.appending(path: id.lowercased() + ".json")
    }
}

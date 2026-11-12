import Foundation
import CryptoKit

struct JournalDraftStorage {
    let directory: URL

    init(userID: Int, root: URL = URL.applicationSupportDirectory.appending(path: "Journal")) {
        directory = root.appending(path: String(userID), directoryHint: .isDirectory)
    }

    func list() throws -> [JournalDraft] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try load(id: $0.deletingPathExtension().lastPathComponent) }
            .sorted { ($0.entryDate, $0.id) > ($1.entryDate, $1.id) }
    }

    func load(id: String) throws -> JournalDraft? {
        let url = try fileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            let draft = try JSONDecoder().decode(JournalDraft.self, from: data)
            guard draft.id == id.lowercased() else { throw CocoaError(.fileReadCorruptFile) }
            return draft
        } catch {
            try preserve(data, from: url)
            throw error
        }
    }

    func save(_ draft: JournalDraft) throws {
        let url = try fileURL(id: draft.id)
        // Never overwrite an unreadable draft before preserving its bytes.
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if (try? JSONDecoder().decode(JournalDraft.self, from: data)) == nil {
                try preserve(data, from: url)
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
    }

    func discard(_ draft: JournalDraft) throws {
        guard try load(id: draft.id)?.editID == draft.editID else { return }
        try FileManager.default.removeItem(at: fileURL(id: draft.id))
    }

    func acknowledge(_ saved: JournalDraft, version: Int) throws {
        guard var current = try load(id: saved.id) else { return }
        if current.editID == saved.editID {
            try discard(current)
        } else if current.expectedVersion == saved.expectedVersion {
            current.expectedVersion = max(current.expectedVersion, version)
            try save(current)
        }
    }

    private func fileURL(id: String) throws -> URL {
        guard ClientIdentifier.isULID(id) else { throw CocoaError(.fileReadInvalidFileName) }
        return directory.appending(path: id.lowercased() + ".json")
    }

    private func preserve(_ data: Data, from url: URL) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let backup = url.appendingPathExtension("recovery-" + digest)
        if !FileManager.default.fileExists(atPath: backup.path) {
            try data.write(to: backup, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

import Foundation
import CryptoKit

struct JournalDraftListing {
    var drafts: [JournalDraft] = []
    var unreadableCount = 0
}

// All reads, comparisons, and writes are synchronous on one actor.
@MainActor
struct JournalDraftStorage {
    let directory: URL

    init(userID: Int, root: URL = URL.applicationSupportDirectory.appending(path: "Journal")) {
        directory = root.appending(path: String(userID), directoryHint: .isDirectory)
    }

    static func remove(userID: Int, root: URL = URL.applicationSupportDirectory.appending(path: "Journal")) throws {
        let directory = JournalDraftStorage(userID: userID, root: root).directory
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func discardAnswers(id: String) throws {
        guard ClientIdentifier.isULID(id) else { throw CocoaError(.fileReadInvalidFileName) }
        let answers = directory.appending(path: "answers/" + id.lowercased())
        if FileManager.default.fileExists(atPath: answers.path) { try FileManager.default.removeItem(at: answers) }
    }

    func list() throws -> JournalDraftListing {
        var result = JournalDraftListing()
        guard FileManager.default.fileExists(atPath: directory.path) else { return result }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        for url in files {
            do {
                if let draft = try load(id: url.deletingPathExtension().lastPathComponent) {
                    result.drafts.append(draft)
                }
            } catch { result.unreadableCount += 1 }
        }
        result.drafts.sort { ($0.entryDate, $0.id) > ($1.entryDate, $1.id) }
        return result
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
            if (try? JSONDecoder().decode(JournalDraft.self, from: data))?.id != draft.id {
                try preserve(data, from: url)
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Unsynced writing remains eligible for device backups.
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

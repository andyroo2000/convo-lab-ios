import Foundation
import CryptoKit

struct JournalAnswerRequest: Codable {
    let id: String
    let payload: JournalAnswerPayload
}

struct JournalAnswerDraft: Codable {
    var answer = ""
    var replace = false
    var request: JournalAnswerRequest?
}

@MainActor
struct JournalAnswerStorage {
    let url: URL
    init(directory: URL, entryID: String, analysisID: String) throws {
        guard ClientIdentifier.isULID(entryID), ClientIdentifier.isULID(analysisID) else { throw CocoaError(.fileReadInvalidFileName) }
        url = directory.appending(path: "answers/\(entryID)/\(analysisID).json")
    }
    func load() throws -> JournalAnswerDraft {
        guard FileManager.default.fileExists(atPath: url.path) else { return JournalAnswerDraft() }
        var draft = try JSONDecoder().decode(JournalAnswerDraft.self, from: Data(contentsOf: url))
        if let request = draft.request, !valid(request, draft: draft) {
            draft.request = nil
            draft.replace = false
        }
        return draft
    }
    private func valid(_ request: JournalAnswerRequest, draft: JournalAnswerDraft) -> Bool {
        ClientIdentifier.isULID(request.id) && request.payload.expectedRevision >= 0
            && request.payload.analysisId == url.deletingPathExtension().lastPathComponent
            && request.payload.answer == draft.answer && request.payload.replace == draft.replace
    }
    func save(_ draft: JournalAnswerDraft) throws {
        if FileManager.default.fileExists(atPath: url.path), (try? load()) == nil {
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try data.write(to: url.appendingPathExtension("recovery-" + digest), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

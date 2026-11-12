import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalCleanupTests: XCTestCase {
    func testAccountCleanupRemovesDraftsAnswersAndRecoveryFilesForOnlyThatAccount() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = JournalDraftStorage(userID: 1, root: root)
        let other = JournalDraftStorage(userID: 2, root: root)
        let draft = JournalDraft.new()
        try owner.save(draft)
        try other.save(draft)
        let answers = owner.directory.appending(path: "answers/" + draft.id)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        try Data("private answer".utf8).write(to: answers.appending(path: "answer.json"))
        try Data("recovery".utf8).write(to: owner.directory.appending(path: "original.recovery"))
        try JournalDraftStorage.remove(userID: 1, root: root)
        try JournalDraftStorage.remove(userID: 1, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owner.directory.path))
        XCTAssertEqual(try other.load(id: draft.id), draft)
    }

    func testDeletingADeviceDraftAlsoRemovesItsAnswerCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = APIClient(baseURL: URL(string: "https://journal.test")!)
        api.setAccessToken("token")
        let store = JournalStore(api: api, userID: 1, storageRoot: root)
        let draft = try store.create()
        let answers = try JournalAnswerStorage(directory: store.storage.directory, entryID: draft.id,
                                               analysisID: "01arz3ndektsv4rrffq69g5fav")
        try answers.save(JournalAnswerDraft(answer: "private"))
        try await store.delete(id: draft.id)
        XCTAssertNil(try store.storage.load(id: draft.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: answers.url.path))
        XCTAssertTrue(store.drafts.isEmpty)
    }
}

import Foundation
import Testing
@testable import ConvoLab

@MainActor
struct JournalDraftTests {
    @Test func clearedTitleIsExplicitNullAndWritingIsUnchanged() throws {
        let input = JournalSavePayload(title: nil, body: "  映画を見た。\n", entryDate: "2026-11-12", expectedVersion: 2)
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONSerialization.jsonObject(with: data)
        let object = try #require(decoded as? [String: Any])
        #expect(object["title"] is NSNull)
        #expect(object["body"] as? String == input.body)
        #expect(object["expectedVersion"] as? Int == 2)
        #expect(object["editID"] == nil)
    }

    @Test func draftsAreAccountScopedAndRejectUnsafePaths() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = JournalDraftStorage(userID: 1, root: root)
        let second = JournalDraftStorage(userID: 2, root: root)
        var draft = JournalDraft.new()
        draft.body = "映画を見ました。"
        try first.save(draft)
        #expect(try first.list() == [draft])
        #expect(try second.list().isEmpty)
        #expect(throws: Error.self) { try first.load(id: "../other") }
        #expect(ClientIdentifier.isULID(draft.id))
        #expect(draft.id == draft.id.lowercased())
    }

    @Test func acknowledgmentKeepsNewerEditsAndAdvancesTheirBaseVersion() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = JournalDraftStorage(userID: 1, root: root)
        let submitted = JournalDraft.new()
        try storage.save(submitted)
        var edited = submitted
        edited.body = "An edit made while saving"
        edited.editID = UUID().uuidString
        try storage.save(edited)
        try storage.acknowledge(submitted, version: 1)
        let retained = try #require(try storage.load(id: edited.id))
        #expect(retained.body == edited.body)
        #expect(retained.expectedVersion == 1)
        try storage.discard(submitted)
        #expect(try storage.load(id: edited.id) != nil)
        try storage.acknowledge(retained, version: 2)
        #expect(try storage.load(id: edited.id) == nil)
    }

    @Test func corruptDraftBytesArePreservedBeforeReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = JournalDraftStorage(userID: 1, root: root)
        let draft = JournalDraft.new()
        try storage.save(draft)
        let url = storage.directory.appending(path: draft.id + ".json")
        let damaged = Data("unreadable original writing".utf8)
        try damaged.write(to: url)
        #expect(throws: Error.self) { try storage.load(id: draft.id) }
        try storage.save(draft)
        let files = try FileManager.default.contentsOfDirectory(at: storage.directory, includingPropertiesForKeys: nil)
        let backup = try #require(files.first { $0.lastPathComponent.contains(".recovery-") })
        #expect(try Data(contentsOf: backup) == damaged)
        #expect(try storage.load(id: draft.id) == draft)
    }
}

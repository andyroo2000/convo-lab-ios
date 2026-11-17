import XCTest
@testable import ConvoLab

@MainActor
final class JournalLandingTests: XCTestCase {
    func testTodayIncludesCompletedAndLocalEntriesButNotOldEntriesOrAnswers() {
        let completed = JournalEntry(id: "a", body: "Completed", entryDate: "2026-11-16", version: 3, createdAt: "now", updatedAt: "now")
        var local = JournalDraft(id: "b", title: nil, body: "Unfinished", entryDate: "2026-11-16", expectedVersion: 0, editID: "edit")
        XCTAssertEqual(JournalSelection.today(entries: [completed], drafts: [], date: "2026-11-16"), "a")
        XCTAssertEqual(JournalSelection.today(entries: [completed], drafts: [local], date: "2026-11-16"), "b")
        local.rootEntryId = "a"
        XCTAssertEqual(JournalSelection.today(entries: [completed], drafts: [local], date: "2026-11-16"), "a")
        XCTAssertNil(JournalSelection.today(entries: [completed], drafts: [], date: "2026-11-17"))
    }

    func testBlankNotebookPersistsOnlyAfterTypingAndKeepsTheSameID() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = APIClient(baseURL: URL(string: "https://journal.test")!)
        api.setAccessToken("journal")
        let store = JournalStore(api: api, userID: 1, storageRoot: root)
        let selection = JournalSelection.blank()
        let model = JournalEntryModel(id: selection.id, store: store, initialDraft: selection.draft)
        await model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.draft?.body, "")
        XCTAssertTrue(store.drafts.isEmpty)
        model.change { $0.body = " " }
        XCTAssertTrue(store.drafts.isEmpty)
        model.change { $0.body = "きょう" }
        model.change { $0.body = "今日、映画を見た。" }
        XCTAssertEqual(store.drafts.count, 1)
        XCTAssertEqual(try store.storage.load(id: selection.id)?.body, "今日、映画を見た。")
        model.change { $0.body = "" }
        XCTAssertEqual(try store.storage.load(id: selection.id)?.body, "")
    }
}

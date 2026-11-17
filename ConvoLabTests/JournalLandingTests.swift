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

    func testUnfinishedLookupMakesOneFilteredRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: configuration))
        api.setAccessToken("journal")
        let entry = JournalEntry(id: "01arz3ndektsv4rrffq69g5fav", body: "Older writing", entryDate: "2026-10-01", version: 1, createdAt: "now", updatedAt: "now")
        let requestMade = expectation(description: "One filtered archive request")
        requestMade.assertForOverFulfill = true
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(url.path, "/api/journal/entries")
            XCTAssertTrue(query.contains(URLQueryItem(name: "unfinished", value: "1")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "limit", value: "1")))
            requestMade.fulfill()
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(JournalArchivePage(data: [entry], nextCursor: nil)))
        }
        defer { MockURLProtocol.handler = nil }
        let found = try await JournalUnfinishedEntry.find(service: JournalService(api: api))
        XCTAssertEqual(found, entry.id)
        await fulfillment(of: [requestMade], timeout: 1)
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

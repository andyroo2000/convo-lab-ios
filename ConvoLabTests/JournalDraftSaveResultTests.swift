import XCTest
@testable import ConvoLab

@MainActor
final class JournalDraftSaveResultTests: XCTestCase {
    private var store: JournalStore!
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: config))
        api.setAccessToken("journal")
        store = JournalStore(api: api, userID: 1, storageRoot: directory)
        MockURLProtocol.deferredHandler = nil
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testOfflineSaveFailsAndPreservesWritingUntilOnlineAcknowledgement() async throws {
        let draft = try store.create()
        let model = JournalEntryModel(id: draft.id, store: store)
        await model.load()
        model.change { $0.body = "映画を見た。" }
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let offline = await model.save(submit: false)
        XCTAssertFalse(offline)
        XCTAssertEqual(try store.storage.load(id: draft.id)?.body, "映画を見た。")
        let entry = JournalEntry(id: draft.id, body: "映画を見た。", entryDate: draft.entryDate, version: 1, createdAt: "now", updatedAt: "now")
        MockURLProtocol.handler = { request in
            let data = try JSONEncoder().encode(JournalResource(data: entry))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let online = await model.save(submit: false)
        XCTAssertTrue(online)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(try store.storage.load(id: draft.id))
    }

    func testUnloadedDraftDoesNotReportSaveSuccess() async {
        let model = JournalEntryModel(id: "01arz3ndektsv4rrffq69g5fav", store: store)
        let saved = await model.save(submit: false)
        XCTAssertFalse(saved)
    }
}

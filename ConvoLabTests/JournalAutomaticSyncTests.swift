import XCTest
@testable import ConvoLab

@MainActor
final class JournalAutomaticSyncTests: XCTestCase {
    private var root: URL!
    private var api: APIClient!
    private var store: JournalStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: config))
        api.setAccessToken("owner-one")
        store = JournalStore(api: api, userID: 1, storageRoot: root)
        MockURLProtocol.deferredHandler = nil
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testOfflineWritingAutomaticallySyncsAfterRestartWithoutOpeningEntry() async throws {
        let draft = try write("Offline writing")
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await store.synchronizeDrafts()
        XCTAssertEqual(try store.storage.load(id: draft.id), draft)
        store = JournalStore(api: api, userID: 1, storageRoot: root)
        respond(entry(draft, version: 1))
        await store.synchronizeDrafts()
        XCTAssertNil(try store.storage.load(id: draft.id))
        XCTAssertEqual(store.entries.first?.body, draft.body)
    }

    func testInterruptedPayloadSurvivesNewerTypingAndRestart() async throws {
        let first = try write("First attempt")
        MockURLProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        await store.synchronizeDrafts()
        var newer = first
        newer.body = "Newer typing"
        newer.editID = UUID().uuidString
        try store.write(newer)
        let checkpoints = JournalSyncStorage(drafts: store.storage)
        XCTAssertEqual(try checkpoints.load(first.id).pending, first)
        store = JournalStore(api: api, userID: 1, storageRoot: root)
        respond(entry(first, version: 1))
        await store.synchronizeDrafts()
        let remaining = try XCTUnwrap(store.storage.load(id: first.id))
        XCTAssertEqual(remaining.body, newer.body)
        XCTAssertEqual(remaining.expectedVersion, 1)
        respond(entry(remaining, version: 2))
        await store.synchronizeDrafts()
        XCTAssertNil(try store.storage.load(id: first.id))
        XCTAssertEqual(store.entries.first?.body, newer.body)
    }

    func testConflictAndDeletionStayPausedAcrossRestart() async throws {
        for status in [404, 409] {
            let draft = try write("Keep this writing")
            respond(["message": "Changed elsewhere"], status: status)
            await store.synchronizeDrafts()
            store = JournalStore(api: api, userID: 1, storageRoot: root)
            MockURLProtocol.handler = { _ in XCTFail("A blocked draft must not be retried"); throw URLError(.cancelled) }
            await store.synchronizeDrafts()
            XCTAssertEqual(store.synchronization.blocked[draft.id], status)
            XCTAssertEqual(try store.storage.load(id: draft.id)?.body, draft.body)
        }
    }

    func testAcknowledgementDoesNotOverwriteNewerEditorText() async throws {
        let draft = try write("Original typing")
        let model = JournalEntryModel(id: draft.id, store: store)
        await model.load()
        var newer = draft
        newer.body = "Continued typing"
        newer.editID = UUID().uuidString
        let checkpoints = JournalSyncStorage(drafts: store.storage)
        try checkpoints.save(JournalSyncCheckpoint(pending: draft), id: draft.id)
        model.change { $0.body = newer.body }
        respond(entry(draft, version: 1))
        await store.synchronizeDrafts()
        model.reconcileSync()
        XCTAssertEqual(model.draft?.body, newer.body)
        XCTAssertEqual(model.draft?.expectedVersion, 1)
        XCTAssertTrue(model.isSavedOnDevice)
    }

    func testChangedSessionNeverUploadsAnotherAccountsDrafts() async throws {
        let draft = try write("Private writing")
        api.setAccessToken("owner-two")
        MockURLProtocol.handler = { _ in XCTFail("Old account must not send"); throw URLError(.cancelled) }
        await store.synchronizeDrafts()
        XCTAssertNotNil(try store.storage.load(id: draft.id))
        let other = JournalStore(api: api, userID: 2, storageRoot: root)
        XCTAssertTrue(other.drafts.isEmpty)
    }

    func testBlankDraftIsNotUploaded() async throws {
        _ = try store.create()
        MockURLProtocol.handler = { _ in XCTFail("Blank writing must stay local"); throw URLError(.cancelled) }
        await store.synchronizeDrafts()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEditingInvalidWritingResumesAutomaticSync() async throws {
        var draft = try write("Invalid writing")
        respond(["message": "Invalid"], status: 422)
        await store.synchronizeDrafts()
        draft.body = "Valid writing"
        draft.editID = UUID().uuidString
        try store.write(draft)
        respond(entry(draft, version: 1))
        await store.synchronizeDrafts()
        XCTAssertNil(try store.storage.load(id: draft.id))
        XCTAssertNil(store.synchronization.blocked[draft.id])
    }

    func testFailedLocalWriteDoesNotClaimServerSync() async throws {
        let saved = entry(try write("Saved original"), version: 1)
        let model = JournalEntryModel(id: saved.id, store: store)
        model.draft = JournalDraft(entry: saved)
        try FileManager.default.removeItem(at: store.storage.directory)
        try Data().write(to: store.storage.directory)
        model.change { $0.body = "Unsaved change" }
        XCTAssertEqual(model.syncStatus, "Not saved on this device")
        XCTAssertEqual(model.draft?.body, "Unsaved change")
    }

    private func write(_ body: String) throws -> JournalDraft {
        var draft = JournalDraft.new()
        draft.body = body
        try store.write(draft)
        return draft
    }

    private func entry(_ draft: JournalDraft, version: Int) -> JournalEntry {
        JournalEntry(id: draft.id, body: draft.body, entryDate: draft.entryDate, version: version, createdAt: "now", updatedAt: "now")
    }

    private func respond<T: Codable & Sendable>(_ value: T, status: Int = 200) {
        let data = try! JSONEncoder().encode(JournalResource(data: value))
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
        }
    }
}

import XCTest
@testable import ConvoLab

@MainActor
final class JournalCrossDeviceTests: XCTestCase {
    private var root: URL!
    private var store: JournalStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: config))
        api.setAccessToken("sync-fixture")
        store = JournalStore(api: api, userID: 1, storageRoot: root)
        MockURLProtocol.deferredHandler = nil
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testRefreshReplacesRemoteCreatesEditsAndDeletionsWithoutDiscardingOfflineWriting() async throws {
        let original = entry()
        respond(JournalArchivePage(data: [original], nextCursor: nil))
        await store.loadMore(refresh: true)
        XCTAssertEqual(store.entries, [original])
        var local = JournalDraft(entry: original)
        local.body = "オフラインで書いた文章。"
        try store.write(local)
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await store.loadMore(refresh: true)
        XCTAssertEqual(store.entries, [original])
        XCTAssertEqual(try store.storage.load(id: original.id), local)
        var edited = original
        edited.title = "Changed on Android"
        edited.version = 2
        let created = entry()
        respond(JournalArchivePage(data: [edited, created], nextCursor: nil))
        await store.loadMore(refresh: true)
        XCTAssertEqual(Set(store.entries.map(\.id)), [original.id, created.id])
        XCTAssertEqual(store.entries.first(where: { $0.id == original.id })?.version, 2)
        respond(JournalArchivePage(data: [created], nextCursor: nil))
        await store.loadMore(refresh: true)
        XCTAssertEqual(store.entries, [created])
        XCTAssertEqual(store.drafts, [local])
    }

    func testOfflineEditOfDeletedEntryCanBeRecoveredWithoutRecreatingDeletedIdentity() async throws {
        try await verifyRecovery(status: 404)
    }

    func testOfflineEditOfNewerEntryCanBeRecoveredWithoutOverwritingRemoteWriting() async throws {
        try await verifyRecovery(status: 409)
    }

    func testDeletionBetweenSaveAndSubmissionOffersRecoveryForTheSavedWriting() async throws {
        let original = entry()
        try store.write(JournalDraft(entry: original))
        let model = JournalEntryModel(id: original.id, store: store)
        await model.load()
        MockURLProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/submit") {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            let state = JournalClarification(id: "01arz3ndektsv4rrffq69g5faz", sourceVersion: original.version, revision: 0, status: .resolved, question: nil, error: nil, updatedAt: "now")
            let data = path.hasSuffix("/clarification")
                ? try JSONEncoder().encode(JournalResource(data: state))
                : try JSONEncoder().encode(JournalResource(data: original))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        await model.save(submit: true)
        XCTAssertTrue(model.hasConflict)
        XCTAssertEqual(model.draft?.body, original.body)
        XCTAssertTrue(model.errorMessage?.contains("save it as a new entry") == true)
        XCTAssertNotEqual(try model.copyAsNew(), original.id)
    }

    private func verifyRecovery(status: Int) async throws {
        let original = entry()
        var local = JournalDraft(entry: original)
        local.body = "オフラインの編集。"
        try store.write(local)
        let model = JournalEntryModel(id: original.id, store: store)
        await model.load()
        respond(["message": "Unavailable"], status: status)
        let saved = await model.save(submit: false)
        XCTAssertFalse(saved)
        XCTAssertTrue(model.hasConflict)
        if status == 404 { XCTAssertTrue(model.errorMessage?.contains("save it as a new entry") == true) }
        XCTAssertEqual(try store.storage.load(id: local.id), local)
        let copyID = try model.copyAsNew()
        XCTAssertNotEqual(copyID, local.id)
        let copy = try XCTUnwrap(store.storage.load(id: copyID))
        XCTAssertEqual(copy.body, local.body)
        XCTAssertEqual(copy.expectedVersion, 0)
        XCTAssertEqual(store.drafts.count, 2)
    }

    func testOfflineDeleteKeepsEntryUntilConfirmedAndCanBeRetriedAfterRemoteDeletion() async throws {
        let original = entry()
        store.accept(original)
        try store.write(JournalDraft(entry: original))
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { try await store.delete(id: original.id); XCTFail("Offline deletion must not succeed") }
        catch { XCTAssertEqual(store.entries, [original]) }
        XCTAssertNotNil(try store.storage.load(id: original.id))
        // The shared API returns 204 for an owned tombstone, including lost-response retries.
        respond([String: String](), status: 204)
        try await store.delete(id: original.id)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(try store.storage.load(id: original.id))
    }

    private func entry() -> JournalEntry {
        JournalEntry(id: JournalDraft.new().id, body: "最初の文章。", entryDate: "2026-11-22", version: 1, createdAt: "now", updatedAt: "now")
    }

    private func respond<T: Encodable>(_ value: T, status: Int = 200) {
        let data = try! JSONEncoder().encode(value)
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
        }
    }
}

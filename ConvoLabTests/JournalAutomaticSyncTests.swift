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

    func testOldReceiptDoesNotReinsertAnEntryDeletedElsewhere() async throws {
        let draft = try write("Disposable writing")
        respond(entry(draft, version: 1))
        await store.synchronizeDrafts()
        let data = try JSONEncoder().encode(JournalArchivePage(data: [], nextCursor: nil))
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        await store.loadMore(refresh: true)
        XCTAssertTrue(store.entries.isEmpty)
        _ = try write("Other offline writing")
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await store.synchronizeDrafts()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRestartAfterAcknowledgementKeepsRebasedNewerWriting() async throws {
        let first = try write("First acknowledged text")
        var newer = first
        newer.body = "Newer text"
        newer.editID = UUID().uuidString
        newer.expectedVersion = 1
        try store.storage.save(newer)
        try JournalSyncStorage(drafts: store.storage).save(JournalSyncCheckpoint(pending: first), id: first.id)
        respond(entry(first, version: 1)) // The API returns this acknowledgement for an identical retry.
        await store.synchronizeDrafts()
        XCTAssertEqual(try store.storage.load(id: first.id), newer)
        respond(entry(newer, version: 2))
        await store.synchronizeDrafts()
        XCTAssertNil(try store.storage.load(id: first.id))
    }

    func testPermissionFailureCanRecoverWithoutCopyingOrDiscardingWriting() async throws {
        let draft = try write("Kept after permission failure")
        respond(["message": "Forbidden"], status: 403)
        await store.synchronizeDrafts()
        store.synchronization.reconnect()
        respond(entry(draft, version: 1))
        await store.synchronizeDrafts()
        XCTAssertNil(store.synchronization.blocked[draft.id])
        XCTAssertNil(try store.storage.load(id: draft.id))
    }

    func testDamagedCheckpointDoesNotMisreportLocalWritingAsUnsaved() async throws {
        let draft = try write("Original local writing")
        let checkpoints = JournalSyncStorage(drafts: store.storage)
        try checkpoints.save(JournalSyncCheckpoint(pending: draft), id: draft.id)
        let file = checkpoints.directory.appending(path: draft.id + ".json")
        try Data("damaged".utf8).write(to: file)
        let model = JournalEntryModel(id: draft.id, store: store)
        await model.load()
        model.change { $0.body = "New writing stays safe" }
        XCTAssertTrue(model.isSavedOnDevice)
        XCTAssertEqual(model.syncStatus, "Saved on this device")
        XCTAssertEqual(try store.storage.load(id: draft.id)?.body, "New writing stays safe")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "damaged")
        XCTAssertFalse(model.canKeepOffline)
    }

    func testExplicitSaveJoinsTheBackgroundRequest() async throws {
        let draft = try write("One request for this writing")
        let model = JournalEntryModel(id: draft.id, store: store)
        await model.load()
        let pending = LockedDeferredResponse()
        let requested = expectation(description: "Only one save request")
        requested.assertForOverFulfill = true
        MockURLProtocol.deferredHandler = { _, completion in
            requested.fulfill()
            pending.hold(completion)
        }
        let background = Task { try await store.synchronization.save(draft) }
        await pending.waitUntilPending()
        let explicit = Task { await model.save(submit: false) }
        for _ in 0..<100 where !model.isBusy { await Task.yield() }
        XCTAssertTrue(model.isBusy)
        let response = HTTPURLResponse(url: URL(string: "https://journal.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        pending.succeed(with: (response, try JSONEncoder().encode(JournalResource(data: entry(draft, version: 1)))))
        _ = try await background.value
        let saved = await explicit.value
        XCTAssertTrue(saved)
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertNil(try store.storage.load(id: draft.id))
    }

    func testDeletionWhileAnotherDraftIsSendingSkipsTheRemovedDraft() async throws {
        try await queuedMutation(delete: true)
    }

    func testBusyEntryIsCheckedAgainAfterAnEarlierRequestCompletes() async throws {
        try await queuedMutation(delete: false)
    }

    private func queuedMutation(delete: Bool) async throws {
        var first = try write("First request")
        first.entryDate = "2026-11-24"
        try store.write(first)
        var second = try write("Do not send this queued draft")
        second.entryDate = "2026-11-23"
        try store.write(second)
        let pending = LockedDeferredResponse()
        let firstID = first.id
        MockURLProtocol.deferredHandler = { request, completion in
            guard request.url!.path.hasSuffix(firstID) else {
                XCTFail("Deleted or busy draft must not start sending")
                completion(.failure(URLError(.cancelled)))
                return
            }
            pending.hold(completion)
        }
        let sync = Task { await store.synchronizeDrafts() }
        await pending.waitUntilPending()
        if delete { try await store.delete(id: second.id) }
        else { try store.beginMutation(id: second.id) }
        let response = HTTPURLResponse(url: URL(string: "https://journal.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        pending.succeed(with: (response, try JSONEncoder().encode(JournalResource(data: entry(first, version: 1)))))
        await sync.value
        store.endMutation(id: second.id)
        XCTAssertEqual(store.entries.map(\.id), [first.id])
        XCTAssertEqual(try store.storage.load(id: second.id) == nil, delete)
    }

    func testDeletingARemotelyMissingEntryClearsItsLocalCopy() async throws {
        let original = entry(try write("Old local copy"), version: 1)
        try store.write(JournalDraft(entry: original))
        respond(["message": "Not found"], status: 404)
        try await store.delete(id: original.id)
        XCTAssertNil(try store.storage.load(id: original.id))
    }

    func testDeletionSettlesAnInterruptedCreateBeforeRemovingItsServerIdentity() async throws {
        let draft = try write("Uncertain creation")
        try JournalSyncStorage(drafts: store.storage).save(JournalSyncCheckpoint(pending: draft), id: draft.id)
        let acknowledged = try JSONEncoder().encode(JournalResource(data: entry(draft, version: 1)))
        let removed = expectation(description: "Delete acknowledged server entry")
        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                removed.fulfill()
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, acknowledged)
        }
        try await store.delete(id: draft.id)
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertNil(try store.storage.load(id: draft.id))
        XCTAssertNil(try JournalSyncStorage(drafts: store.storage).load(draft.id).pending)
    }

    func testClosingAcknowledgedWritingDoesNotResendAStaleSnapshot() async throws {
        let draft = try write("Already saved on iOS")
        let model = JournalEntryModel(id: draft.id, store: store)
        await model.load()
        respond(entry(draft, version: 1))
        await store.synchronizeDrafts()
        model.reconcileSync()
        MockURLProtocol.handler = { _ in
            XCTFail("Closing clean writing must not overwrite or conflict with a newer remote edit")
            throw URLError(.cancelled)
        }
        let closed = await model.save(submit: false)
        XCTAssertTrue(closed)
        XCTAssertNil(try store.storage.load(id: draft.id))
        XCTAssertNil(try JournalSyncStorage(drafts: store.storage).load(draft.id).pending)
    }

    func testManualSavePreservesMemoryOnlyTypingOverAnOlderDiskDraft() async throws {
        let original = try write("Older disk draft")
        let model = JournalEntryModel(id: original.id, store: store)
        await model.load()
        let directory = store.storage.directory
        let backup = directory.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data().write(to: directory)
        model.change { $0.body = "Latest memory-only typing" }
        XCTAssertEqual(model.syncStatus, "Not saved on this device")
        let failed = await model.save(submit: false)
        XCTAssertFalse(failed)
        XCTAssertEqual(model.draft?.body, "Latest memory-only typing")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        let response = try JSONEncoder().encode(JournalResource(data: entry(try XCTUnwrap(model.draft), version: 1)))
        MockURLProtocol.handler = { request in
            let payload = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            XCTAssertEqual(payload?["body"] as? String, "Latest memory-only typing")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let saved = await model.save(submit: false)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.draft?.body, "Latest memory-only typing")
        XCTAssertEqual(model.syncStatus, "Synced")
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

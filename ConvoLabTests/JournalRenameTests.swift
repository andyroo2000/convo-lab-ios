import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalRenameTests: XCTestCase {
    private var root: URL!
    private var store: JournalStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: config))
        api.setAccessToken("token")
        store = JournalStore(api: api, userID: 1, storageRoot: root)
        MockURLProtocol.deferredHandler = nil
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testOfflineRenamePreservesWritingWithoutNetwork() async throws {
        MockURLProtocol.handler = { _ in XCTFail("No network expected"); throw URLError(.notConnectedToInternet) }
        var draft = try store.create()
        draft.body = "Private writing"
        try store.write(draft)
        try await store.rename(draft, title: "  Movie night  ")
        let saved = try XCTUnwrap(store.storage.load(id: draft.id))
        XCTAssertEqual(saved.title, "Movie night")
        XCTAssertEqual(saved.body, draft.body)
        XCTAssertEqual(saved.expectedVersion, 0)
        XCTAssertNotEqual(saved.editID, draft.editID)
    }

    func testSavedRenameDoesNotPublishUnsavedWriting() async throws {
        let draft = try savedDraft()
        respond(id: draft.id, version: 3)
        try await store.rename(draft, title: "New title")
        let local = try XCTUnwrap(store.storage.load(id: draft.id))
        XCTAssertEqual(local.title, "New title")
        XCTAssertEqual(local.body, "Private writing")
        XCTAssertEqual(local.expectedVersion, 4)
        XCTAssertEqual(store.entries.first?.body, "Saved writing")
    }

    func testConcurrentServerChangeRetainsDeviceDraft() async throws {
        let draft = try savedDraft()
        respond(id: draft.id, version: 4)
        do { try await store.rename(draft, title: "New title"); XCTFail("Expected conflict") }
        catch APIClientError.rejected(let status, _) { XCTAssertEqual(status, 409) }
        XCTAssertEqual(try store.storage.load(id: draft.id), draft)
    }

    func testFailedSaveAndBlankTitleRetainDeviceDraft() async throws {
        let draft = try savedDraft()
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { try await store.rename(draft, title: "New title"); XCTFail("Expected failure") } catch {}
        do { try await store.rename(draft, title: "   "); XCTFail("Expected validation failure") }
        catch APIClientError.rejected(let status, _) { XCTAssertEqual(status, 422) }
        XCTAssertEqual(try store.storage.load(id: draft.id), draft)
    }

    func testSameTitleWithNewerRemoteBodyDoesNotAdvanceLocalVersion() async throws {
        let draft = try savedDraft()
        respond(id: draft.id, version: 4, title: "New title")
        try await store.rename(draft, title: "New title")
        let local = try XCTUnwrap(store.storage.load(id: draft.id))
        XCTAssertEqual(local.title, "New title")
        XCTAssertEqual(local.expectedVersion, 3)
        XCTAssertEqual(local.body, "Private writing")
    }

    func testRenamePreservesEditsMadeWhileReadingTheSavedEntry() async throws {
        let draft = try savedDraft()
        let deferred = LockedDeferredResponse()
        MockURLProtocol.deferredHandler = { _, completion in deferred.hold(completion) }
        let renaming = Task { try await store.rename(draft, title: "New title") }
        await deferred.waitUntilPending()
        var newer = draft
        newer.title = "New local title"
        newer.body = "More private writing"
        newer.editID = UUID().uuidString
        try store.write(newer)
        MockURLProtocol.deferredHandler = nil
        respond(id: draft.id, version: 3)
        deferred.succeed(with: try Self.response(id: draft.id, title: "Original", version: 3))
        try await renaming.value
        let saved = try XCTUnwrap(store.storage.load(id: draft.id))
        XCTAssertEqual(saved.title, newer.title)
        XCTAssertEqual(saved.body, newer.body)
        XCTAssertEqual(saved.expectedVersion, 4)
        XCTAssertNotEqual(saved.editID, newer.editID)
    }

    func testRowMutationsWaitForAnEditorSaveToFinish() async throws {
        let draft = try savedDraft()
        let model = JournalEntryModel(id: draft.id, store: store)
        await model.load()
        let deferred = LockedDeferredResponse()
        MockURLProtocol.deferredHandler = { _, completion in deferred.hold(completion) }
        let saving = Task { await model.save(submit: false) }
        await deferred.waitUntilPending()
        do { try await store.rename(draft, title: "New title"); XCTFail("Expected busy rejection") }
        catch APIClientError.rejected(let status, _) { XCTAssertEqual(status, 409) }
        do { try await store.delete(id: draft.id); XCTFail("Expected busy rejection") }
        catch APIClientError.rejected(let status, _) { XCTAssertEqual(status, 409) }
        XCTAssertTrue(store.busyEntryIDs.contains(draft.id))
        deferred.succeed(with: try Self.response(id: draft.id, title: "Original", version: 4))
        await saving.value
        XCTAssertTrue(store.busyEntryIDs.isEmpty)
    }

    private func savedDraft() throws -> JournalDraft {
        var draft = try store.create()
        draft.title = "Original"
        draft.body = "Private writing"
        draft.expectedVersion = 3
        try store.write(draft)
        return draft
    }

    private func respond(id: String, version: Int, title: String = "Original") {
        MockURLProtocol.handler = { request in
            let saving = request.httpMethod == "PUT"
            if saving {
                let data = try Self.body(request)
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(payload["body"] as? String, "Saved writing")
                XCTAssertEqual(payload["title"] as? String, "New title")
                XCTAssertEqual(payload["expectedVersion"] as? Int, version)
            }
            return try Self.response(id: id, title: saving ? "New title" : title, version: saving ? version + 1 : version)
        }
    }

    nonisolated private static func response(id: String, title: String, version: Int) throws -> (HTTPURLResponse, Data) {
        let entry: [String: Any] = ["id": id, "title": title, "body": "Saved writing",
                                    "entryDate": "2026-11-13", "version": version, "createdAt": "now", "updatedAt": "now"]
        let response = HTTPURLResponse(url: URL(string: "https://journal.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, try JSONSerialization.data(withJSONObject: ["data": entry]))
    }

    nonisolated private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

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

    private func savedDraft() throws -> JournalDraft {
        var draft = try store.create()
        draft.title = "Original"
        draft.body = "Private writing"
        draft.expectedVersion = 3
        try store.write(draft)
        return draft
    }

    private func respond(id: String, version: Int) {
        MockURLProtocol.handler = { request in
            let saving = request.httpMethod == "PUT"
            if saving {
                XCTAssertEqual(version, 3, "A stale rename must never save")
                let data = try Self.body(request)
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(payload["body"] as? String, "Saved writing")
                XCTAssertEqual(payload["title"] as? String, "New title")
                XCTAssertEqual(payload["expectedVersion"] as? Int, version)
            }
            let entry: [String: Any] = ["id": id, "title": saving ? "New title" : "Original", "body": "Saved writing",
                                        "entryDate": "2026-11-13", "version": saving ? version + 1 : version, "createdAt": "now", "updatedAt": "now"]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONSerialization.data(withJSONObject: ["data": entry]))
        }
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

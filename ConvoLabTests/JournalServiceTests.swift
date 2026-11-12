import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalServiceTests: XCTestCase {
    private var root: URL!
    private var api: APIClient!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: configuration))
        api.setAccessToken("journal-token")
        MockURLProtocol.deferredHandler = nil
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testOfflineDraftCanBeCreatedAndEditedWithoutNetwork() throws {
        MockURLProtocol.handler = { _ in XCTFail("No request expected"); throw URLError(.notConnectedToInternet) }
        let store = JournalStore(api: api, userID: 1, storageRoot: root)
        var draft = try store.create()
        draft.body = "映画を見ました。"
        draft.editID = UUID().uuidString
        try store.write(draft)
        XCTAssertEqual(store.drafts.first?.body, draft.body)
        XCTAssertEqual(try store.storage.load(id: draft.id)?.body, draft.body)
    }

    func testChangedAccountCannotWriteOrRequestOldJournal() async throws {
        MockURLProtocol.handler = { _ in XCTFail("Old session must not request"); throw URLError(.cancelled) }
        let store = JournalStore(api: api, userID: 1, storageRoot: root)
        let draft = try store.create()
        api.setAccessToken("another-account")
        XCTAssertThrowsError(try store.write(draft))
        do { _ = try await store.service.archive(); XCTFail("Expected rejection") }
        catch APIClientError.rejected(let status, _) { XCTAssertEqual(status, 401) }
    }

    func testSavePreservesNullTitleAndExactWriting() async throws {
        let store = JournalStore(api: api, userID: 1, storageRoot: root)
        var draft = try store.create()
        draft.body = "  映画を見た。\n"
        let id = draft.id
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer journal-token")
            let data = try Self.requestBody(request)
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertTrue(input["title"] is NSNull)
            XCTAssertEqual(input["body"] as? String, "  映画を見た。\n")
            let entry: [String: Any] = ["id": id, "title": NSNull(), "body": "  映画を見た。\n", "entryDate": "2026-11-12", "version": 1, "createdAt": "now", "updatedAt": "now"]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONSerialization.data(withJSONObject: ["data": entry]))
        }
        let saved = try await store.service.save(draft)
        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(saved.body, draft.body)
    }

    func testFailedSaveKeepsDeviceWriting() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let store = JournalStore(api: api, userID: 1, storageRoot: root)
        let draft = try store.create()
        let model = JournalEntryModel(id: draft.id, store: store)
        await model.load()
        model.change { $0.body = "まだ保存していない文章。" }
        await model.save(submit: true)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.isEditing)
        XCTAssertEqual(try store.storage.load(id: draft.id)?.body, "まだ保存していない文章。")
    }

    nonisolated private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

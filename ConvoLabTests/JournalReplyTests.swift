import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalReplyTests: XCTestCase {
    private var root: URL!
    private var entry: JournalEntryModel!
    private var storage: JournalAnswerStorage!
    private let analysisID = "01arz3ndektsv4rrffq69g5faw"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: configuration))
        api.setAccessToken("journal-token")
        let store = JournalStore(api: api, userID: 1, storageRoot: root)
        let draft = try store.create()
        entry = JournalEntryModel(id: draft.id, store: store)
        await entry.load()
        entry.analysis = JournalAnalysis(id: analysisID, sourceVersion: 1, status: .ready, result: nil, error: nil, updatedAt: "now", replyRevision: 0)
        storage = try JournalAnswerStorage(directory: store.storage.directory, entryID: draft.id, analysisID: analysisID)
    }
    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testLostResponseKeepsTheSameRequestAndWritingAcrossReopen() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let model = JournalReplyModel(entry: entry, storage: storage)
        model.change("友達と。")
        await model.submit()
        let first = try XCTUnwrap(model.draft.request)
        let reopened = JournalReplyModel(entry: entry, storage: storage)
        await reopened.submit()
        XCTAssertEqual(reopened.draft.request?.id, first.id)
        XCTAssertEqual(reopened.draft.answer, "友達と。")
        XCTAssertTrue(reopened.waiting)
        XCTAssertEqual(first.payload.analysisId, analysisID)
        XCTAssertEqual(first.payload.expectedRevision, 0)
    }

    func testMissingRequestAllowsEditingWithoutLosingTheAnswer() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let model = JournalReplyModel(entry: entry, storage: storage)
        model.change("友達と。")
        await model.submit()
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        try await model.checkPending()
        XCTAssertFalse(model.waiting)
        model.change("妹と。")
        XCTAssertNil(model.draft.request)
        XCTAssertEqual(try storage.load().answer, "妹と。")
    }

    func testConfirmationClearsOnlyTheAppliedRequest() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let model = JournalReplyModel(entry: entry, storage: storage)
        model.change("友達と。")
        await model.submit()
        let id = try XCTUnwrap(model.draft.request?.id)
        entry.analysis?.currentReply = JournalReply(id: id, parentId: nil, answer: "友達と。", status: .ready, result: nil, error: nil)
        entry.analysis?.replyRevision = 1
        model.reconcile()
        XCTAssertEqual(model.draft.answer, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.url.path))
    }

    func testRemoteRevisionKeepsTextForDeliberateResubmission() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let model = JournalReplyModel(entry: entry, storage: storage)
        model.change("友達と。")
        await model.submit()
        entry.analysis?.replyRevision = 2
        model.reconcile()
        XCTAssertEqual(model.draft.answer, "友達と。")
        XCTAssertNil(model.draft.request)
        XCTAssertFalse(model.waiting)
    }

    func testUndoSendsDisplayedRevisionAndRefreshesTheModel() async throws {
        entry.analysis?.replyRevision = 4
        var response = try XCTUnwrap(entry.analysis)
        response.replyRevision = 5
        let data = try JSONEncoder().encode(JournalResource(data: response))
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/undo"))
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open(); defer { stream.close() }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: stream) as? [String: Any])
            XCTAssertEqual(body["expectedRevision"] as? Int, 4)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        await JournalReplyModel(entry: entry, storage: storage).undo()
        XCTAssertEqual(entry.analysis?.replyRevision, 5)
    }
}

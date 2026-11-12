import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalDocumentModelTests: XCTestCase {
    private var root: URL!
    private var api: APIClient!
    private var entry: JournalEntryModel!
    private let analysisID = "01arz3ndektsv4rrffq69g5faw"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: configuration))
        api.setAccessToken("journal-token")
        let store = JournalStore(api: api, userID: 1, storageRoot: root)
        let draft = try store.create()
        entry = JournalEntryModel(id: draft.id, store: store)
        await entry.load()
        entry.analysis = JournalAnalysis(id: analysisID, sourceVersion: 1, status: .ready, result: nil, error: nil,
            updatedAt: "now", replyRevision: 2, correctedDocument: .init(text: "Edited", reading: "Edited", suggestions: [.init(id: analysisID + ":0", applied: false)]))
        MockURLProtocol.deferredHandler = nil
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testPendingReplyAndMissingSuggestionDoNotSendRequests() async {
        MockURLProtocol.handler = { _ in XCTFail("No request expected"); throw URLError(.cancelled) }
        let model = JournalDocumentModel(entry: entry)
        let missing = await model.toggle(.init(id: "missing", applied: false))
        XCTAssertFalse(missing)
        entry.analysis?.pendingReplyId = "pending"
        let blocked = await model.save(payload())
        XCTAssertFalse(blocked)
    }

    func testStaleSuggestionUsesTheCurrentAppliedState() async throws {
        let response = try XCTUnwrap(entry.analysis)
        MockURLProtocol.handler = { request in
            let input = try JSONDecoder().decode(JournalSuggestionTestPayload.self, from: Self.body(request))
            XCTAssertTrue(input.applied)
            XCTAssertEqual(input.expectedRevision, 2)
            return try Self.response(request, analysis: response)
        }
        let result = await JournalDocumentModel(entry: entry).toggle(.init(id: analysisID + ":0", applied: true))
        XCTAssertTrue(result)
    }

    func testOlderResponseCannotReplaceNewerRefreshAndBusyPreventsDuplicateSave() async throws {
        let started = delayedResponse(try XCTUnwrap(entry.analysis))
        let model = JournalDocumentModel(entry: entry)
        let input = payload()
        let task = Task { await model.save(input) }
        await fulfillment(of: [started], timeout: 2)
        let duplicate = await model.save(input)
        XCTAssertFalse(duplicate)
        entry.analysis?.replyRevision = 9
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertEqual(entry.analysis?.replyRevision, 9)
    }

    func testAccountSwitchRejectsLateResponseWithoutChangingTheEntry() async throws {
        let started = delayedResponse(try XCTUnwrap(entry.analysis))
        let model = JournalDocumentModel(entry: entry)
        let input = payload()
        let task = Task { await model.save(input) }
        await fulfillment(of: [started], timeout: 2)
        api.setAccessToken("another-account")
        let saved = await task.value
        XCTAssertFalse(saved)
        XCTAssertEqual(entry.analysis?.replyRevision, 2)
        XCTAssertNotNil(model.errorMessage)
    }

    func testFailureRefreshesAndKeepsAnActionableError() async {
        let refreshed = expectation(description: "Refresh after conflict")
        MockURLProtocol.handler = { request in
            if request.httpMethod == "GET" { refreshed.fulfill() }
            return (HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, Data(#"{"message":"Changed elsewhere"}"#.utf8))
        }
        let model = JournalDocumentModel(entry: entry)
        let saved = await model.save(payload())
        XCTAssertFalse(saved)
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertNotNil(model.errorMessage)
    }

    private func delayedResponse(_ analysis: JournalAnalysis) -> XCTestExpectation {
        let started = expectation(description: "Save started")
        MockURLProtocol.deferredHandler = { request, completion in
            started.fulfill()
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                completion(Result { try Self.response(request, analysis: analysis) })
            }
        }
        return started
    }

    private func payload() -> JournalCorrectedPayload {
        .init(analysisId: analysisID, expectedRevision: 2, text: "Edited")
    }

    nonisolated private static func response(_ request: URLRequest, analysis: JournalAnalysis) throws -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(JournalResource(data: analysis)))
    }

    nonisolated private static func body(_ request: URLRequest) throws -> Data {
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

nonisolated private struct JournalSuggestionTestPayload: Decodable {
    let applied: Bool
    let expectedRevision: Int
}

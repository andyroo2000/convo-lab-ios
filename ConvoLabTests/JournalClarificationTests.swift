import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalClarificationTests: XCTestCase {
    private var api: APIClient!
    private let entry = JournalEntry(id: "01arz3ndektsv4rrffq69g5fav", body: "映画を見た。", entryDate: "2026-11-12", version: 3, createdAt: "now", updatedAt: "now")
    private let sessionID = "01arz3ndektsv4rrffq69g5faw"

    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: config))
        api.setAccessToken("journal")
        MockURLProtocol.deferredHandler = nil
    }
    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
    }

    func testQuestionsReplaceEachOtherBeforeResolving() async throws {
        respond("waiting", question: "Who was driving?")
        let model = JournalClarificationModel(service: JournalService(api: api))
        let completion = Task { await model.begin(entry) }
        try await waitUntil { model.state?.question?.prompt == "Who was driving?" && !model.busy }
        respond("waiting", question: "Were you or Molly driving?")
        model.answer("Yes")
        try await waitUntil { model.state?.question?.prompt == "Were you or Molly driving?" && !model.busy }
        XCTAssertTrue(model.active)
        respond("waiting", question: "Which scene was unclear?")
        model.answer("I was driving")
        try await waitUntil { model.state?.question?.prompt == "Which scene was unclear?" && !model.busy }
        respond("resolved")
        model.answer("The last scene")
        let result = await completion.value
        XCTAssertEqual(result, sessionID)
        XCTAssertFalse(model.active)
        XCTAssertNil(model.state)
    }

    func testFailureCanRetryWithoutCompletingSubmission() async throws {
        respond("failed", error: "Try again")
        let model = JournalClarificationModel(service: JournalService(api: api))
        let completion = Task { await model.begin(entry) }
        try await waitUntil { model.errorMessage != nil && !model.busy }
        XCTAssertTrue(model.active)
        respond("resolved")
        model.retry()
        let result = await completion.value
        XCTAssertEqual(result, sessionID)
    }

    func testCancelPreservesNoPendingContinuation() async throws {
        respond("waiting", question: "Who was driving?")
        let model = JournalClarificationModel(service: JournalService(api: api))
        let completion = Task { await model.begin(entry) }
        try await waitUntil { model.state != nil && !model.busy }
        model.cancel()
        let result = await completion.value
        XCTAssertNil(result)
        XCTAssertFalse(model.active)
        respond("resolved")
        let retried = await model.begin(entry)
        XCTAssertEqual(retried, sessionID)
    }

    func testWrongVersionCannotCompleteAndChangedAccountCannotRetry() async throws {
        respond("resolved", version: 2)
        let model = JournalClarificationModel(service: JournalService(api: api))
        let completion = Task { await model.begin(entry) }
        try await waitUntil { model.errorMessage != nil && !model.busy }
        XCTAssertTrue(model.active)
        api.setAccessToken("someone-else")
        model.retry()
        try await waitUntil { model.errorMessage?.contains("session changed") == true && !model.busy }
        model.cancel()
        let result = await completion.value
        XCTAssertNil(result)
    }

    func testRequestsSendVersionQuestionAnswerAndResolvedID() async throws {
        let service = JournalService(api: api)
        respond("waiting", question: "Who was driving?")
        let state = try await service.startClarification(entry)
        MockURLProtocol.handler = { request in
            let body = try Self.body(request)
            XCTAssertEqual(body["expectedVersion"] as? Int, 3)
            XCTAssertEqual(body["questionId"] as? String, "01arz3ndektsv4rrffq69g5fax")
            XCTAssertEqual(body["answer"] as? String, "I was driving")
            XCTAssertTrue(request.url!.path.hasSuffix("/clarification/01arz3ndektsv4rrffq69g5faw/answer"))
            return Self.response(request, json: #"{"data":{"id":"01arz3ndektsv4rrffq69g5faw","sourceVersion":3,"revision":1,"status":"resolved","question":null,"error":null,"updatedAt":"now"}}"#)
        }
        _ = try await service.answerClarification(entry, state: state, answer: "I was driving")
        MockURLProtocol.handler = { request in
            let body = try Self.body(request)
            XCTAssertEqual(body["expectedVersion"] as? Int, 3)
            XCTAssertEqual(body["clarificationId"] as? String, "01arz3ndektsv4rrffq69g5faw")
            return Self.response(request, json: #"{"data":{"id":"01arz3ndektsv4rrffq69g5fay","sourceVersion":3,"status":"queued","result":null,"error":null,"updatedAt":"now"}}"#)
        }
        _ = try await service.submit(entry, clarificationID: sessionID)
    }

    private func respond(_ status: String, question: String? = nil, error: String? = nil, version: Int = 3) {
        let data: [String: Any] = ["id": sessionID, "sourceVersion": version, "revision": 0, "status": status,
            "question": question.map { ["id": "01arz3ndektsv4rrffq69g5fax", "prompt": $0, "choices": ["Me", "Molly"]] } as Any? ?? NSNull(), "error": error as Any? ?? NSNull(), "updatedAt": "now"]
        let encoded = try! JSONSerialization.data(withJSONObject: ["data": data])
        MockURLProtocol.handler = { request in (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, encoded) }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Clarification did not reach expected state")
    }
    nonisolated private static func response(_ request: URLRequest, json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }
    nonisolated private static func body(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = stream.read(&bytes, maxLength: bytes.count)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes.prefix(max(0, count)))) as? [String: Any])
    }
}

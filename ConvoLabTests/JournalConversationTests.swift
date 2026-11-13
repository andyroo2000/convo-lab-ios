import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalConversationTests: XCTestCase {
    private var directory: URL!
    private var store: JournalStore!
    private let rootID = "01arz3ndektsv4rrffq69g5fav"
    private let childID = "01arz3ndektsv4rrffq69g5faw"
    private let questionID = "01arz3ndektsv4rrffq69g5fax"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: config))
        api.setAccessToken("journal-token")
        store = JournalStore(api: api, userID: 1, storageRoot: directory)
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        MockURLProtocol.deferredHandler = nil
    }
    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }
    func testReplyDraftAndSavedEntryStayOutOfArchive() throws {
        let entry = child()
        store.accept(entry)
        try store.write(JournalDraft(entry: entry))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(try store.storage.load(id: childID)?.rootEntryId, rootID)
    }
    func testConversationSnapshotLoadsWithoutExtraRequestsAndLocalEditsWin() async throws {
        let entry = child()
        let node = JournalConversationNode(entry: entry, analysis: nil, question: nil, parentEntryId: rootID)
        let model = JournalEntryModel(id: childID, store: store, initial: node)
        await model.load()
        XCTAssertEqual(model.draft?.body, "友達と見た。")
        XCTAssertNil(model.errorMessage)
        model.change { $0.body = "妻と見た。" }
        let reopened = JournalEntryModel(id: childID, store: store, initial: node)
        await reopened.load()
        XCTAssertEqual(reopened.draft?.body, "妻と見た。")
        XCTAssertTrue(reopened.isEditing)
    }
    func testUncertainSubmissionRestoresExactRequestForRetry() async throws {
        let entry = JournalEntryModel(id: rootID, store: store)
        let answer = JournalConversationAnswer(entry: entry, rootID: rootID, analysisID: childID)
        answer.body = "友達と見た。"
        await answer.submit(questionID: questionID, refresh: { XCTFail("Failed creation must not clear the answer"); return false })
        let request = try XCTUnwrap(answer.request)
        let restored = JournalConversationAnswer(entry: entry, rootID: rootID, analysisID: childID)
        XCTAssertEqual(restored.request?.id, request.id)
        XCTAssertEqual(restored.request?.questionId, questionID)
        XCTAssertEqual(restored.request?.body, "友達と見た。")
        XCTAssertNotNil(answer.errorMessage)
    }
    func testOversizedAnswerRemainsEditableWithoutCreatingRequest() async {
        let entry = JournalEntryModel(id: rootID, store: store)
        let answer = JournalConversationAnswer(entry: entry, rootID: rootID, analysisID: childID)
        answer.body = String(repeating: "あ", count: 20001)
        await answer.submit(questionID: questionID, refresh: { XCTFail("No request expected"); return false })
        XCTAssertNil(answer.request)
        XCTAssertNotNil(answer.errorMessage)
    }
    func testRefreshedSnapshotUpdatesSavedReplyButPreservesEditing() async {
        let entry = child()
        let first = JournalConversationNode(entry: entry, analysis: nil, question: nil, parentEntryId: rootID)
        let model = JournalEntryModel(id: childID, store: store, initial: first)
        await model.load()
        let updated = JournalEntry(id: childID, title: nil, body: "妻と見た。", entryDate: entry.entryDate, version: 2, createdAt: "now", updatedAt: "later", rootEntryId: rootID)
        let snapshot = JournalConversationNode(entry: updated, analysis: nil, question: nil, parentEntryId: rootID)
        await model.load(snapshot: snapshot)
        XCTAssertEqual(model.draft?.body, updated.body)
        model.isEditing = true
        model.change { $0.body = "一人で見た。" }
        await model.load(snapshot: first)
        XCTAssertEqual(model.draft?.body, "一人で見た。")
    }
    func testSavedAnswerKeepsRecoveryUntilConversationRefreshSucceeds() async throws {
        let entry = child()
        MockURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/submit") { throw URLError(.notConnectedToInternet) }
            return try Self.response(request.url!, entry)
        }
        let parent = JournalEntryModel(id: rootID, store: store)
        let answer = JournalConversationAnswer(entry: parent, rootID: rootID, analysisID: childID)
        answer.body = entry.body
        await answer.submit(questionID: questionID, refresh: { false })
        XCTAssertEqual(answer.errorMessage, "Your answer is saved. Reload the conversation to see it.")
        let restored = JournalConversationAnswer(entry: parent, rootID: rootID, analysisID: childID)
        XCTAssertEqual(restored.request?.id, answer.request?.id)
        await restored.submit(questionID: questionID, refresh: { true })
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(JournalConversationAnswer(entry: parent, rootID: rootID, analysisID: childID).body, "")
    }
    func testSavedNestedQuestionUsesItsParentAndKeepsTutor() async throws {
        let question = JournalTutorQuestion(id: questionID, text: "何を話した？", reading: "何[なに]を話[はな]した？", translation: "What did you talk about?", tutor: JournalTutor(id: "hana", name: "Hana", gender: "F", avatar: "hana-v1"))
        let parentID = childID
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/api/journal/entries/" + parentID + "/questions/" + question.id + "/retry")
            return try Self.response(request.url!, question)
        }
        let tutor = JournalTutorModel(entryID: childID, service: store.service, savedQuestion: question)
        await tutor.load()
        XCTAssertEqual(tutor.question?.translation, question.translation)
        XCTAssertEqual(tutor.question?.tutor?.id, "hana")
        XCTAssertNil(tutor.errorMessage)
    }
    nonisolated private static func response<Value: Codable & Sendable>(_ url: URL, _ value: Value) throws -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(JournalResource(data: value)))
    }
    private func child() -> JournalEntry {
        JournalEntry(id: childID, title: nil, body: "友達と見た。", entryDate: "2026-11-13", version: 1, createdAt: "now", updatedAt: "now", rootEntryId: rootID)
    }
}

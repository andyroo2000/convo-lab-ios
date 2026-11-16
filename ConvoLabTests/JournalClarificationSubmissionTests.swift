import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalClarificationSubmissionTests: XCTestCase {
    private var store: JournalStore!
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: config))
        api.setAccessToken("journal")
        store = JournalStore(api: api, userID: 1, storageRoot: directory)
        MockURLProtocol.deferredHandler = nil
    }
    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }
    func testEntryWaitsBeforeFeedbackAndCancelKeepsWriting() async throws {
        let draft = try store.create()
        let model = JournalEntryModel(id: draft.id, store: store)
        await model.load()
        model.change { $0.body = "私が運転した。" }
        let entry = JournalEntry(id: draft.id, body: "私が運転した。", entryDate: draft.entryDate, version: 1, createdAt: "now", updatedAt: "now")
        prepare(entry)
        let pending = Task { await model.save(submit: true) }
        try await waitForQuestion(model.clarification)
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.isSubmitting)
        XCTAssertNil(model.analysis)
        model.clarification.cancel()
        await pending.value
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.draft?.body, entry.body)
        XCTAssertTrue(model.isEditing)
    }
    func testReplyCancellationKeepsItsSavedRequestForRetry() async throws {
        let entry = JournalEntry(id: "01arz3ndektsv4rrffq69g5fav", body: "私が運転した。", entryDate: "2026-11-12", version: 1, createdAt: "now", updatedAt: "now")
        prepare(entry)
        let parent = JournalEntryModel(id: entry.id, store: store)
        let answer = JournalConversationAnswer(entry: parent, rootID: entry.id, analysisID: "analysis")
        answer.body = entry.body
        let pending = Task { await answer.submit(questionID: "01arz3ndektsv4rrffq69g5fax", refresh: { XCTFail("Must wait for clarification"); return true }) }
        try await waitForQuestion(answer.clarification)
        answer.clarification.cancel()
        await pending.value
        XCTAssertEqual(answer.body, entry.body)
        let restored = JournalConversationAnswer(entry: parent, rootID: entry.id, analysisID: "analysis")
        XCTAssertEqual(restored.request?.id, answer.request?.id)
        XCTAssertNotNil(restored.request)
    }
    func testSuccessfulSubmissionResetsFinalPreferenceAndKeepsThinkingDuringRequest() async throws {
        let draft = try store.create()
        let model = JournalEntryModel(id: draft.id, store: store)
        await model.load()
        let key = JournalVersion.preferenceKey(owner: store.storage.directory.lastPathComponent, entry: draft.id)
        UserDefaults.standard.set(JournalVersion.final.rawValue, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let entry = JournalEntry(id: draft.id, body: draft.body, entryDate: draft.entryDate, version: 1, createdAt: "now", updatedAt: "now")
        let submitted = expectation(description: "Feedback requested")
        MockURLProtocol.handler = { request in
            let data: Data
            if request.url!.path.hasSuffix("/clarification") {
                let state = JournalClarification(id: "01arz3ndektsv4rrffq69g5faz", sourceVersion: 1, revision: 0, status: .resolved, question: nil, error: nil, updatedAt: "now")
                data = try JSONEncoder().encode(JournalResource(data: state))
            } else if request.url!.path.hasSuffix("/submit") {
                submitted.fulfill()
                let analysis = JournalAnalysis(id: "analysis", sourceVersion: 1, status: .queued, result: nil, error: nil, updatedAt: "now")
                data = try JSONEncoder().encode(JournalResource(data: analysis))
            } else { data = try JSONEncoder().encode(JournalResource(data: entry)) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let saved = await model.save(submit: true)
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertTrue(saved)
        XCTAssertFalse(model.isSubmitting)
        XCTAssertEqual(model.analysis?.status, .queued)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), JournalVersion.draft.rawValue)
    }

    func testMissingEntryIsFriendlyButLocalWritingSurvives404Save() async throws {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let missing = JournalEntryModel(id: "01arz3ndektsv4rrffq69g5fav", store: store)
        await missing.load()
        XCTAssertTrue(missing.missingEntry)
        XCTAssertNil(missing.errorMessage)
        let draft = try store.create()
        let local = JournalEntryModel(id: draft.id, store: store)
        await local.load()
        local.change { $0.body = "Still on this device" }
        let saved = await local.save(submit: false)
        XCTAssertFalse(saved)
        XCTAssertFalse(local.missingEntry)
        XCTAssertEqual(local.draft?.body, "Still on this device")
        XCTAssertNotNil(local.errorMessage)
    }

    private func prepare(_ entry: JournalEntry) {
        MockURLProtocol.handler = { request in
            XCTAssertFalse(request.url!.path.hasSuffix("/submit"), "Feedback must wait for answers")
            let data: Data
            if request.url!.path.hasSuffix("/clarification") {
                let state = JournalClarification(id: "01arz3ndektsv4rrffq69g5faz", sourceVersion: entry.version, revision: 0, status: .waiting, question: .init(id: "01arz3ndektsv4rrffq69g5fax", prompt: "Who was driving?", choices: ["Me", "Molly"]), error: nil, updatedAt: "now")
                data = try JSONEncoder().encode(JournalResource(data: state))
            } else { data = try JSONEncoder().encode(JournalResource(data: entry)) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
    }
    private func waitForQuestion(_ model: JournalClarificationModel) async throws {
        for _ in 0..<100 {
            if model.state?.status == .waiting && !model.busy { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected a clarification question")
    }
}

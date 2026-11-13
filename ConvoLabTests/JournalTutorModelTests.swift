import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalTutorModelTests: XCTestCase {
    private var api: APIClient!
    private var root: URL!
    private var model: JournalTutorModel!
    private let hana = JournalTutor(id: "hana", name: "Hana", gender: "F", avatar: "hana-v1")
    private let ren = JournalTutor(id: "ren", name: "Ren", gender: "M", avatar: "ren-v1")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: config))
        api.setAccessToken("journal-token")
        let store = JournalStore(api: api, userID: 1, storageRoot: root)
        let entry = JournalEntryModel(id: try store.create().id, store: store)
        let analysis = JournalAnalysis(id: "01arz3ndektsv4rrffq69g5faw", sourceVersion: 1, status: .ready, result: nil, error: nil, updatedAt: "now", replyRevision: 0)
        model = JournalTutorModel(entry: entry, analysis: analysis)
        let question = JournalTutorQuestion(id: "01arz3ndektsv4rrffq69g5fax", text: "どうでしたか。", reading: "どうでしたか。", translation: "How was it?", tutor: hana)
        let preferences = JournalTutorPreferences(selectedId: "hana", tutors: [hana, ren])
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/question") == true { return try Self.response(request.url!, question) }
            return try Self.response(request.url!, preferences)
        }
        await model.load()
        await model.showPicker()
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testChangedDefaultKeepsTheExistingQuestionTutor() async throws {
        let question = try XCTUnwrap(model.question)
        let preferences = JournalTutorPreferences(selectedId: "ren", tutors: [hana, ren])
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/question") == true { return try Self.response(request.url!, question) }
            XCTAssertEqual(request.httpMethod, "PUT")
            return try Self.response(request.url!, preferences)
        }
        await model.choose(ren)
        XCTAssertEqual(model.preferences?.selectedId, "ren")
        XCTAssertEqual(model.question?.tutor?.id, "hana")
        XCTAssertFalse(model.choosing)
    }

    func testFailedPreferenceSaveKeepsTheChooserAndExistingQuestion() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await model.choose(ren)
        XCTAssertTrue(model.choosing)
        XCTAssertEqual(model.preferences?.selectedId, "hana")
        XCTAssertEqual(model.question?.tutor?.id, "hana")
        XCTAssertNotNil(model.errorMessage)
    }

    func testPreparationFailureAfterSavedPreferenceKeepsChooserOpen() async throws {
        let preferences = JournalTutorPreferences(selectedId: "ren", tutors: [hana, ren])
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/question") == true { throw URLError(.notConnectedToInternet) }
            return try Self.response(request.url!, preferences)
        }
        await model.choose(ren)
        XCTAssertTrue(model.choosing)
        XCTAssertEqual(model.preferences?.selectedId, "ren")
        XCTAssertEqual(model.question?.tutor?.id, "hana")
        XCTAssertNotNil(model.errorMessage)
    }

    func testMonitorLoadsReadyAudioAndRetainsTutor() async throws {
        var queued = try XCTUnwrap(model.question)
        queued.audio = JournalQuestionAudioState(status: "queued", error: nil)
        let initial = queued
        MockURLProtocol.handler = { request in try Self.response(request.url!, initial) }
        await model.load()
        queued.audio = JournalQuestionAudioState(status: "ready", error: nil)
        let ready = queued
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url!.path.hasSuffix("/questions/" + ready.id))
            return try Self.response(request.url!, ready)
        }
        await model.monitorAudio()
        XCTAssertEqual(model.question?.audio?.status, "ready")
        XCTAssertEqual(model.question?.tutor?.id, "hana")
    }

    func testAccountSwitchRejectsLateTutorPreferenceResponse() async throws {
        let deferred = LockedDeferredResponse()
        let preferences = JournalTutorPreferences(selectedId: "ren", tutors: [hana, ren])
        MockURLProtocol.deferredHandler = { _, completion in deferred.hold(completion) }
        let choosing = Task { await model.choose(ren) }
        await deferred.waitUntilPending()
        api.setAccessToken("different-account")
        deferred.succeed(with: try Self.response(URL(string: "https://journal.test")!, preferences))
        await choosing.value
        XCTAssertEqual(model.preferences?.selectedId, "hana")
        XCTAssertNotNil(model.errorMessage)
    }

    nonisolated private static func response<Value: Codable & Sendable>(_ url: URL, _ value: Value) throws -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(JournalResource(data: value)))
    }
}

import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalVoiceSelectionTests: XCTestCase {
    private var api: APIClient!
    private let entryID = "01arz3ndektsv4rrffq69g5fav"
    private let analysis = JournalAnalysis(id: "analysis", sourceVersion: 1, status: .ready, result: nil, error: nil, updatedAt: "now", replyRevision: 3)

    override func setUp() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: configuration))
        api.setAccessToken("journal-token")
        MockURLProtocol.deferredHandler = nil
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
    }

    func testEntryVoiceAndNewEntryDefaultComeFromTheServerRatherThanCatalogOrder() async {
        for hasAudio in [true, false] {
            MockURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer journal-token")
                if request.url?.path.hasSuffix("/voices") == true { return Self.catalog(request) }
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "analysisId" })?.value, "analysis")
                XCTAssertEqual(query?.first(where: { $0.name == "expectedReplyRevision" })?.value, "3")
                return Self.response(request, body: "{\"data\":{\"voiceId\":\"yua\",\"hasAudio\":\(hasAudio)}}")
            }
            let selection = JournalVoiceSelection()
            XCTAssertFalse(selection.isReady)
            await selection.load(entryID: entryID, analysis: analysis, service: JournalService(api: api))
            XCTAssertEqual(selection.selected, "yua")
            XCTAssertEqual(selection.voices.map(\.name), ["Haru (M)", "Yua (F)"])
            XCTAssertTrue(selection.isReady)
        }
    }

    func testPreferenceFailureDoesNotEnableFallbackPlaybackAndCanBeRetried() async {
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/voices") == true { return Self.catalog(request) }
            throw URLError(.notConnectedToInternet)
        }
        let selection = JournalVoiceSelection()
        let service = JournalService(api: api)
        await selection.load(entryID: entryID, analysis: analysis, service: service)
        XCTAssertFalse(selection.isReady)
        XCTAssertEqual(selection.selected, "")
        XCTAssertNotNil(selection.errorMessage)
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/voices") == true { return Self.catalog(request) }
            return Self.response(request, body: #"{"data":{"voiceId":"haru","hasAudio":false}}"#)
        }
        await selection.load(entryID: entryID, analysis: analysis, service: service)
        XCTAssertTrue(selection.isReady)
        XCTAssertEqual(selection.selected, "haru")
        XCTAssertNil(selection.errorMessage)
    }

    func testAnUnavailableSavedVoiceRequiresAnExplicitChoice() async {
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/voices") == true { return Self.catalog(request) }
            return Self.response(request, body: #"{"data":{"voiceId":"removed","hasAudio":true}}"#)
        }
        let selection = JournalVoiceSelection()
        await selection.load(entryID: entryID, analysis: analysis, service: JournalService(api: api))
        XCTAssertFalse(selection.isReady)
        XCTAssertEqual(selection.selected, "")
        selection.selected = "yua"
        XCTAssertTrue(selection.isReady)
    }

    func testLeavingTheEntryIgnoresDelayedPreferenceResults() async throws {
        let started = expectation(description: "Both preference requests started")
        started.expectedFulfillmentCount = 2
        MockURLProtocol.deferredHandler = { request, completion in
            started.fulfill()
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                let response = request.url?.path.hasSuffix("/voices") == true
                    ? Self.catalog(request)
                    : Self.response(request, body: #"{"data":{"voiceId":"yua","hasAudio":true}}"#)
                completion(.success(response))
            }
        }
        let selection = JournalVoiceSelection()
        let service = JournalService(api: api)
        let task = Task { await selection.load(entryID: entryID, analysis: analysis, service: service) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(selection.isReady)
        selection.cancel()
        await task.value
        XCTAssertFalse(selection.isReady)
        XCTAssertEqual(selection.selected, "")
        XCTAssertTrue(selection.voices.isEmpty)
    }

    nonisolated private static func catalog(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        response(request, body: #"{"data":[{"id":"haru","name":"Haru (M)"},{"id":"yua","name":"Yua (F)"}]}"#)
    }

    func testCancelledLoadDoesNotShowAnErrorOrEnablePlayback() async {
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/voices") == true { return Self.catalog(request) }
            return Self.response(request, body: #"{"data":{"voiceId":"yua","hasAudio":true}}"#)
        }
        let selection = JournalVoiceSelection()
        let service = JournalService(api: api)
        let task = Task { await selection.load(entryID: entryID, analysis: analysis, service: service) }
        task.cancel()
        await task.value
        XCTAssertNil(selection.errorMessage)
        XCTAssertFalse(selection.isReady)
        XCTAssertEqual(selection.selected, "")
    }

    func testNewRevisionReplacesThePreviousRevisionsVoice() async {
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/voices") == true { return Self.catalog(request) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let revision = query?.first(where: { $0.name == "expectedReplyRevision" })?.value
            let voice = revision == "3" ? "yua" : "haru"
            return Self.response(request, body: "{\"data\":{\"voiceId\":\"\(voice)\",\"hasAudio\":false}}")
        }
        let selection = JournalVoiceSelection()
        let service = JournalService(api: api)
        await selection.load(entryID: entryID, analysis: analysis, service: service)
        XCTAssertEqual(selection.selected, "yua")
        let revised = JournalAnalysis(id: analysis.id, sourceVersion: 1, status: .ready, result: nil, error: nil, updatedAt: "now", replyRevision: 4)
        await selection.load(entryID: entryID, analysis: revised, service: service)
        XCTAssertEqual(selection.selected, "haru")
        XCTAssertTrue(selection.isReady)
    }

    nonisolated private static func response(_ request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!, Data(body.utf8))
    }
}

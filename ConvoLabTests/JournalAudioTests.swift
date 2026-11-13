import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class JournalAudioTests: XCTestCase {
    private var api: APIClient!
    override func setUp() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: configuration))
        api.setAccessToken("journal-token")
    }
    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
    }

    func testAudioCarriesAuthenticationAndTheDisplayedReplyRevision() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/journal/entries/01arz3ndektsv4rrffq69g5fav/audio")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer journal-token")
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open(); defer { stream.close() }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: stream) as? [String: Any])
            XCTAssertEqual(object["analysisId"] as? String, "analysis")
            XCTAssertEqual(object["voiceId"] as? String, "ren")
            XCTAssertEqual(object["expectedReplyRevision"] as? Int, 3)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "audio/mpeg"])!, Data([1, 2, 3]))
        }
        let result = try await JournalService(api: api).audio(entryID: "01arz3ndektsv4rrffq69g5fav",
            body: JournalAudioPayload(analysisId: "analysis", voiceId: "ren", expectedReplyRevision: 3))
        XCTAssertEqual(result, Data([1, 2, 3]))
    }

    func testQuestionAudioDownloadsExistingRecordingWithAuthentication() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/journal/entries/01arz3ndektsv4rrffq69g5fav/questions/01arz3ndektsv4rrffq69g5fax/audio")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer journal-token")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data([4, 5, 6]))
        }
        let data = try await JournalService(api: api).questionAudio(entryID: "01arz3ndektsv4rrffq69g5fav", questionID: "01arz3ndektsv4rrffq69g5fax")
        XCTAssertEqual(data, Data([4, 5, 6]))
    }

    func testQuestionAudioRejectsLateResponseAfterAccountSwitch() async throws {
        let deferred = LockedDeferredResponse()
        let service = JournalService(api: api)
        MockURLProtocol.deferredHandler = { _, completion in deferred.hold(completion) }
        let task = Task { try await service.questionAudio(entryID: "01arz3ndektsv4rrffq69g5fav", questionID: "01arz3ndektsv4rrffq69g5fax") }
        await deferred.waitUntilPending()
        api.setAccessToken("other-account")
        deferred.succeed(with: (HTTPURLResponse(url: URL(string: "https://journal.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data([1])))
        do { _ = try await task.value; XCTFail("Must reject another account's recording") }
        catch { XCTAssertNotNil(error as? APIClientError) }
    }

    func testStartingAnotherPlayerInvalidatesPendingRecording() async throws {
        let requested = expectation(description: "First recording requested")
        let deferred = LockedDeferredResponse()
        MockURLProtocol.deferredHandler = { _, completion in deferred.hold(completion); requested.fulfill() }
        let first = JournalAudioPlayer()
        let service = JournalService(api: api)
        let task = Task { await first.toggle { try await service.questionAudio(entryID: "01arz3ndektsv4rrffq69g5fav", questionID: "01arz3ndektsv4rrffq69g5fax") } }
        await fulfillment(of: [requested], timeout: 2)
        let second = JournalAudioPlayer()
        await second.toggle { throw URLError(.notConnectedToInternet) }
        deferred.succeed(with: (HTTPURLResponse(url: URL(string: "https://journal.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data([1])))
        await task.value
        XCTAssertFalse(first.preparing)
        XCTAssertFalse(first.isPlaying)
        XCTAssertNil(first.errorMessage)
    }

    func testStoppingPendingAudioIgnoresItsLateFailure() async throws {
        let requested = expectation(description: "Audio requested")
        MockURLProtocol.deferredHandler = { _, completion in
            requested.fulfill()
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                completion(.failure(URLError(.notConnectedToInternet)))
            }
        }
        let player = JournalAudioPlayer()
        let service = JournalService(api: api)
        let analysis = JournalAnalysis(id: "analysis", sourceVersion: 1, status: .ready, result: nil, error: nil, updatedAt: "now")
        let task = Task { await player.toggle(entryID: "01arz3ndektsv4rrffq69g5fav", analysis: analysis, voice: "ren", service: service) }
        await fulfillment(of: [requested], timeout: 2)
        player.stop()
        await task.value
        XCTAssertFalse(player.preparing)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.errorMessage)
    }
}

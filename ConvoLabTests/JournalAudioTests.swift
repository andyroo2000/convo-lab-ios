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

import XCTest
@testable import ConvoLab

final class ReadingSyncTests: XCTestCase {
    @MainActor
    func testFailedSaveSurvivesRelaunchAndClearsOnlyAfterAcknowledgement() async throws {
        let owner = -401
        defer { try? ReadingLocalStorage.remove(userID: owner); MockURLProtocol.handler = nil }
        try ReadingLocalStorage.remove(userID: owner)
        let api = client()
        let store = ReadingStore(api: api, userID: owner)
        store.record(reading(), pageNumber: 24, sentence: nil)
        let original = try XCTUnwrap(store.snapshot.pending["reading"])
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        await store.synchronizePositions()
        let restored = ReadingStore(api: api, userID: owner)
        XCTAssertEqual(restored.snapshot.pending["reading"]?.eventId, original.eventId)
        let response = try Self.acknowledgement(original)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        await restored.synchronizePositions()
        XCTAssertTrue(restored.snapshot.pending.isEmpty)
        XCTAssertTrue(try ReadingLocalStorage(userID: owner).load().pending.isEmpty)
    }

    @MainActor
    func testAccountChangeStopsPendingSaves() async throws {
        let owner = -402
        defer { try? ReadingLocalStorage.remove(userID: owner); MockURLProtocol.handler = nil }
        try ReadingLocalStorage.remove(userID: owner)
        let api = client()
        let store = ReadingStore(api: api, userID: owner)
        store.record(reading(), pageNumber: 24, sentence: 0)
        api.setAccessToken("another-account")
        MockURLProtocol.handler = { _ in
            XCTFail("Old account must not issue a request with the new account token")
            throw URLError(.cancelled)
        }
        await store.synchronizePositions()
        XCTAssertEqual(store.snapshot.pending.count, 1)
    }

    @MainActor
    func testNewLocalPositionDuringAnAcknowledgementIsNotDiscarded() async throws {
        let owner = -403
        defer {
            try? ReadingLocalStorage.remove(userID: owner)
            MockURLProtocol.handler = nil
            MockURLProtocol.deferredHandler = nil
        }
        try ReadingLocalStorage.remove(userID: owner)
        let api = client()
        let store = ReadingStore(api: api, userID: owner)
        let document = reading()
        store.record(document, pageNumber: 24, sentence: nil)
        let old = try Self.acknowledgement(XCTUnwrap(store.snapshot.pending["reading"]))
        MockURLProtocol.deferredHandler = { request, complete in
            Task { @MainActor in
                store.record(document, pageNumber: 25, sentence: nil)
                let newer = try Self.acknowledgement(XCTUnwrap(store.snapshot.pending["reading"]))
                MockURLProtocol.deferredHandler = nil
                MockURLProtocol.handler = { next in
                    (HTTPURLResponse(url: next.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, newer)
                }
                complete(.success((HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, old)))
            }
        }
        await store.synchronizePositions()
        XCTAssertTrue(store.snapshot.pending.isEmpty)
        XCTAssertEqual(store.position("reading")?.pageNumber, 25)
    }

    @MainActor
    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://readings.invalid")!, session: URLSession(configuration: configuration))
        api.setAccessToken("fixture")
        return api
    }

    @MainActor
    private static func acknowledgement(_ position: ReadingPosition) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(position))
        return try JSONSerialization.data(withJSONObject: ["position": object])
    }

    @MainActor
    private func reading() -> ReadingDetail {
        ReadingDetail(id: "reading", title: "Story", revision: 1, document: ReadingDocument(title: "Story", author: "Author", pages: [
            ReadingPage(number: 24, kind: "text", columns: [[ReadingSegment(index: 0, text: "犬です。")]]),
            ReadingPage(number: 25, kind: "text", columns: [[ReadingSegment(index: 0, text: "犬です。")]])
        ], sentences: [ReadingSentence(text: "犬です。", translation: "A dog.")]), voiceId: "voice", voiceName: "Narrator")
    }
}

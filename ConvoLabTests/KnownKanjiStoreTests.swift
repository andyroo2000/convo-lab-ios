import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class KnownKanjiStoreTests: XCTestCase {
    @MainActor
    func testConnectSubmitsTokenWithoutPersistingItAndRefreshesEffectiveKnowledge() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let requestCounter = LockedCounter()
        let connectedSnapshot = Data(
            #"""
            {
              "version": 2,
              "kanji": ["会"],
              "manualKanji": [],
              "wanikani": {
                "connected": true,
                "lastSyncedAt": "2026-07-24T04:00:00.000000Z"
              }
            }
            """#.utf8
        )
        let client = makeClient { request in
            switch requestCounter.next() {
            case 1:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.url?.path, "/api/study/wanikani")
                let body = try requestBody(request)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                )
                XCTAssertEqual(object["apiToken"], "secret-wanikani-token")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    connectedSnapshot
                )
            case 2:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/study/wanikani/sync")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"added":1,"effectiveTotal":1,"version":2}"#.utf8)
                )
            default:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/study/known-kanji")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    connectedSnapshot
                )
            }
        }
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
        )
        store.activate(userID: 7)

        await store.connectWaniKani(apiToken: "secret-wanikani-token")

        XCTAssertNil(store.wanikaniErrorMessage)
        XCTAssertTrue(store.wanikaniConnected)
        XCTAssertEqual(store.knownKanji, ["会"])
        XCTAssertEqual(requestCounter.current, 3)
        let persisted = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalKnownKanjiSnapshot>()).first
        )
        XCTAssertFalse(
            String(decoding: persisted.payload, as: UTF8.self)
                .contains("secret-wanikani-token")
        )
    }

    @MainActor
    func testKnownKanjiRefreshPersistsPerUserForOfflineLaunch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/known-kanji")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"""
                    {
                      "version": 4,
                      "kanji": ["会", "社"],
                      "manualKanji": ["社"],
                      "wanikani": {
                        "connected": true,
                        "lastSyncedAt": "2026-07-24T04:00:00.000000Z"
                      }
                    }
                    """#.utf8
                )
            )
        }
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        store.activate(userID: 7)

        try await store.refreshKnownKanji()

        XCTAssertEqual(store.knownKanji, ["会", "社"])
        XCTAssertEqual(store.manualKnownKanji, ["社"])
        XCTAssertTrue(store.wanikaniConnected)
        XCTAssertNotNil(store.wanikaniLastSyncedAt)

        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let relaunched = StudyStore(
            api: offlineClient,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        relaunched.activate(userID: 7)
        XCTAssertEqual(relaunched.knownKanji, ["会", "社"])
        XCTAssertTrue(relaunched.wanikaniConnected)

        relaunched.activate(userID: 8)
        XCTAssertTrue(relaunched.knownKanji.isEmpty)
        XCTAssertFalse(relaunched.wanikaniConnected)
    }

    @MainActor
    func testDisconnectRetainsServerEffectiveKnowledgeSnapshot() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            if request.httpMethod == "DELETE" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 204,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"""
                    {
                      "version": 5,
                      "kanji": ["会"],
                      "manualKanji": [],
                      "wanikani": {"connected": false, "lastSyncedAt": null}
                    }
                    """#.utf8
                )
            )
        }
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(api: client, context: container.mainContext)
        )
        store.activate(userID: 7)

        await store.disconnectWaniKani()

        XCTAssertNil(store.wanikaniErrorMessage)
        XCTAssertFalse(store.wanikaniConnected)
        XCTAssertEqual(store.knownKanji, ["会"])
    }

    @MainActor
    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }

    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? URLError(.cannotDecodeContentData)
        }
        if count == 0 {
            return body
        }
        body.append(buffer, count: count)
    }
}

import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

final class KnownKanjiStoreTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    @MainActor
    func testStudyStorePublishesKnownKanjiServiceChanges() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"{"version":1,"kanji":["会"],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                )
            )
        }
        let store = StudyStore(
            initialUserID: 7,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 7,
                api: client,
                context: container.mainContext
            )
        )
        let changed = expectation(description: "Known kanji observation changed")
        withObservationTracking {
            _ = store.knownKanji
        } onChange: {
            changed.fulfill()
        }

        try await store.refreshKnownKanji()

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(store.knownKanji, ["会"])
    }

    @MainActor
    func testStudyStorePublishesWaniKaniWorkingAndErrorChanges() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let (requestStarted, requestStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseRequest, releaseRequestContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            requestStartedContinuation.yield()
            Task {
                for await _ in releaseRequest {
                    completion(.success((
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 503,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        Data(#"{"message":"WaniKani is unavailable"}"#.utf8)
                    )))
                    return
                }
            }
        }
        let store = StudyStore(
            initialUserID: 7,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 7,
                api: client,
                context: container.mainContext
            )
        )
        let workingChanged = expectation(description: "WaniKani working observation changed")
        withObservationTracking {
            _ = store.isWaniKaniWorking
        } onChange: {
            workingChanged.fulfill()
        }

        let synchronization = Task { await store.syncWaniKani() }
        for await _ in requestStarted {
            break
        }
        await fulfillment(of: [workingChanged], timeout: 1)
        XCTAssertTrue(store.isWaniKaniWorking)

        let errorChanged = expectation(description: "WaniKani error observation changed")
        withObservationTracking {
            _ = store.wanikaniErrorMessage
        } onChange: {
            errorChanged.fulfill()
        }
        releaseRequestContinuation.yield()
        await synchronization.value

        await fulfillment(of: [errorChanged], timeout: 1)
        XCTAssertFalse(store.isWaniKaniWorking)
        XCTAssertEqual(store.wanikaniErrorMessage, "WaniKani is unavailable")
    }

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
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
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
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
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
        let relaunched = StudyStore(initialUserID: 1,
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
    func testOlderKnownKanjiSnapshotCannotRegressCurrentState() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let requestCounter = LockedCounter()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/known-kanji")
            let version: Int
            let kanji: String
            if requestCounter.next() == 1 {
                version = 5
                kanji = #"["会","社"]"#
            } else {
                version = 4
                kanji = #"["会"]"#
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {
                      "version": \(version),
                      "kanji": \(kanji),
                      "manualKanji": [],
                      "wanikani": {"connected": true, "lastSyncedAt": null}
                    }
                    """.utf8
                )
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        store.activate(userID: 7)

        try await store.refreshKnownKanji()
        try await store.refreshKnownKanji()

        XCTAssertEqual(store.knownKanjiVersion, 5)
        XCTAssertEqual(store.knownKanji, ["会", "社"])
        let persisted = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalKnownKanjiSnapshot>()).first
        )
        let snapshot = try StorageCodec.decoder.decode(
            KnownKanjiSnapshot.self,
            from: persisted.payload
        )
        XCTAssertEqual(snapshot.version, 5)
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
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        store.activate(userID: 7)

        await store.disconnectWaniKani()

        XCTAssertNil(store.wanikaniErrorMessage)
        XCTAssertFalse(store.wanikaniConnected)
        XCTAssertEqual(store.knownKanji, ["会"])
    }

    @MainActor
    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func makeDeferredClient(
        handler: @escaping MockURLProtocol.DeferredHandler
    ) -> APIClient {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }
}

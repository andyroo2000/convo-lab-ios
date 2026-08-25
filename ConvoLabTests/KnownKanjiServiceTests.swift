import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class KnownKanjiServiceTests: XCTestCase {
    @MainActor
    func testConnectPersistsTheReturnedSnapshotThenSynchronizes() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let requestCounter = LockedCounter()
        let client = makeClient { request in
            switch requestCounter.next() {
            case 1:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.url?.path, "/api/study/wanikani")
                let body = try requestBody(request)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                )
                XCTAssertEqual(object["apiToken"], "secret-token")
                return Self.jsonResponse(
                    for: request,
                    body: Self.snapshotJSON(version: 1, kanji: ["会"], connected: true)
                )
            case 2:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/study/wanikani/sync")
                return Self.jsonResponse(
                    for: request,
                    body: #"{"added":1,"effectiveTotal":2,"version":2}"#
                )
            default:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/study/known-kanji")
                return Self.jsonResponse(
                    for: request,
                    body: Self.snapshotJSON(
                        version: 2,
                        kanji: ["会", "社"],
                        connected: true
                    )
                )
            }
        }
        let service = KnownKanjiService(api: client, context: container.mainContext)
        service.activate(userID: 7)

        await service.connect(apiToken: "secret-token")

        XCTAssertNil(service.errorMessage)
        XCTAssertFalse(service.isWorking)
        XCTAssertEqual(service.knownKanji, ["会", "社"])
        XCTAssertEqual(service.version, 2)
        XCTAssertEqual(requestCounter.current, 3)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalKnownKanjiSnapshot>()).first
        )
        XCTAssertEqual(record.userID, 7)
        XCTAssertFalse(String(decoding: record.payload, as: UTF8.self).contains("secret-token"))
    }

    @MainActor
    func testSynchronizePostsThenRefreshesEffectiveKnowledge() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let requestCounter = LockedCounter()
        let client = makeClient { request in
            if requestCounter.next() == 1 {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/study/wanikani/sync")
                return Self.jsonResponse(
                    for: request,
                    body: #"{"added":2,"effectiveTotal":2,"version":4}"#
                )
            }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/study/known-kanji")
            return Self.jsonResponse(
                for: request,
                body: Self.snapshotJSON(version: 4, kanji: ["会", "社"], connected: true)
            )
        }
        let service = KnownKanjiService(api: client, context: container.mainContext)
        service.activate(userID: 7)

        await service.synchronize()

        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(service.knownKanji, ["会", "社"])
        XCTAssertEqual(requestCounter.current, 2)
    }

    @MainActor
    func testDisconnectRefreshesAndRetainsServerEffectiveKnowledge() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let requestCounter = LockedCounter()
        let client = makeClient { request in
            if requestCounter.next() == 1 {
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.url?.path, "/api/study/wanikani")
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
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/study/known-kanji")
            return Self.jsonResponse(
                for: request,
                body: Self.snapshotJSON(version: 5, kanji: ["会"], connected: false)
            )
        }
        let service = KnownKanjiService(api: client, context: container.mainContext)
        service.activate(userID: 7)

        await service.disconnect()

        XCTAssertNil(service.errorMessage)
        XCTAssertFalse(service.wanikaniConnected)
        XCTAssertEqual(service.knownKanji, ["会"])
        XCTAssertEqual(requestCounter.current, 2)
    }

    @MainActor
    func testUpdatesAndPersistsTheTransferBridgeStatus() async throws {
        let canonicalRequest = try Self.compatibilityCaseData(
            fixture: "wanikani-transfer-bridge-update-v1",
            caseID: "enable",
            field: "request"
        )
        let canonicalResponse = try Self.compatibilityCaseData(
            fixture: "wanikani-transfer-bridge-update-v1",
            caseID: "enable",
            field: "response"
        )
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(
            LocalKnownKanjiSnapshot(
                userID: 7,
                payload: Data(
                    Self.snapshotJSON(version: 0, kanji: [], connected: true).utf8
                )
            )
        )
        try container.mainContext.save()
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/api/study/wanikani/transfer-bridge")
            let body = try requestBody(request)
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: body) as? [String: Bool],
                try JSONSerialization.jsonObject(with: canonicalRequest) as? [String: Bool]
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                canonicalResponse
            )
        }
        let service = KnownKanjiService(api: client, context: container.mainContext)
        service.activate(userID: 7)

        await service.setTransferBridgeEnabled(true)

        XCTAssertNil(service.errorMessage)
        XCTAssertFalse(service.isWorking)
        XCTAssertTrue(service.transferBridgeStatus.enabled)
        XCTAssertEqual(service.transferBridgeStatus.importedVocabularyCount, 0)
        XCTAssertEqual(service.transferBridgeStatus.pendingVocabularyCount, 0)
        XCTAssertEqual(service.transferBridgeStatus.failedVocabularyCount, 0)
        XCTAssertNil(service.transferBridgeStatus.lastImportedAt)
        let persisted = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalKnownKanjiSnapshot>()).first
        )
        let snapshot = try StorageCodec.decoder.decode(
            KnownKanjiSnapshot.self,
            from: persisted.payload
        )
        XCTAssertEqual(snapshot.wanikani.transferBridge, service.transferBridgeStatus)
    }

    @MainActor
    func testActivateLoadsOnlyTheSelectedUsersStoredSnapshot() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(
            LocalKnownKanjiSnapshot(
                userID: 7,
                payload: Data(Self.snapshotJSON(version: 2, kanji: ["会"], connected: true).utf8)
            )
        )
        container.mainContext.insert(
            LocalKnownKanjiSnapshot(
                userID: 8,
                payload: Data(Self.snapshotJSON(version: 3, kanji: ["社"], connected: false).utf8)
            )
        )
        try container.mainContext.save()
        let requestCounter = LockedCounter()
        let service = KnownKanjiService(
            api: makeClient { request in
                _ = requestCounter.next()
                return Self.jsonResponse(for: request, body: "{}")
            },
            context: container.mainContext
        )

        service.activate(userID: 7)
        XCTAssertEqual(service.knownKanji, ["会"])
        XCTAssertTrue(service.wanikaniConnected)

        service.activate(userID: 8)
        XCTAssertEqual(service.knownKanji, ["社"])
        XCTAssertFalse(service.wanikaniConnected)

        service.activate(userID: 9)
        XCTAssertTrue(service.knownKanji.isEmpty)
        XCTAssertEqual(service.version, -1)
        XCTAssertEqual(requestCounter.current, 0)
    }

    @MainActor
    func testFailedSynchronizePreservesSnapshotAndReportsError() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(
            LocalKnownKanjiSnapshot(
                userID: 7,
                payload: Data(Self.snapshotJSON(version: 2, kanji: ["会"], connected: true).utf8)
            )
        )
        try container.mainContext.save()
        let service = KnownKanjiService(
            api: makeClient { request in
                (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"WaniKani is unavailable"}"#.utf8)
                )
            },
            context: container.mainContext
        )
        service.activate(userID: 7)

        await service.synchronize()

        XCTAssertEqual(service.knownKanji, ["会"])
        XCTAssertEqual(service.errorMessage, "WaniKani is unavailable")
        XCTAssertFalse(service.isWorking)
    }

    @MainActor
    func testOperationsWithoutAnActiveUserAreNoOps() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let requestCounter = LockedCounter()
        let service = KnownKanjiService(
            api: makeClient { request in
                _ = requestCounter.next()
                return Self.jsonResponse(for: request, body: "{}")
            },
            context: container.mainContext
        )

        try await service.refresh()
        await service.connect(apiToken: "unused")
        await service.synchronize()
        await service.disconnect()

        XCTAssertEqual(requestCounter.current, 0)
        XCTAssertFalse(service.isWorking)
        XCTAssertNil(service.errorMessage)
    }

    @MainActor
    func testReactivationDropsAnOlderInFlightRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(
            LocalKnownKanjiSnapshot(
                userID: 7,
                payload: Data(
                    Self.snapshotJSON(version: 10, kanji: ["社"], connected: false).utf8
                )
            )
        )
        try container.mainContext.save()
        let (requestStarted, requestStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseRequest, releaseRequestContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            requestStartedContinuation.yield()
            Task {
                for await _ in releaseRequest {
                    completion(.success(Self.jsonResponse(
                        for: request,
                        body: Self.snapshotJSON(version: 11, kanji: ["会"], connected: true)
                    )))
                    return
                }
            }
        }
        let service = KnownKanjiService(api: client, context: container.mainContext)
        service.activate(userID: 7)
        let refresh = Task { try await service.refresh() }
        for await _ in requestStarted {
            break
        }

        service.activate(userID: 8)
        service.activate(userID: 7)
        XCTAssertEqual(service.knownKanji, ["社"])
        XCTAssertEqual(service.version, 10)
        releaseRequestContinuation.yield()
        try await refresh.value

        XCTAssertEqual(service.knownKanji, ["社"])
        XCTAssertEqual(service.version, 10)
        let persisted = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalKnownKanjiSnapshot>()).first
        )
        XCTAssertEqual(
            try StorageCodec.decoder.decode(KnownKanjiSnapshot.self, from: persisted.payload)
                .kanji,
            ["社"]
        )
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

    private static func jsonResponse(
        for request: URLRequest,
        body: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }

    private static func snapshotJSON(
        version: Int,
        kanji: [String],
        connected: Bool
    ) -> String {
        let encodedKanji = kanji.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {
          "version": \(version),
          "kanji": [\(encodedKanji)],
          "manualKanji": [],
          "wanikani": {"connected": \(connected), "lastSyncedAt": null}
        }
        """
    }

    private static func compatibilityCaseData(
        fixture: String,
        caseID: String,
        field: String
    ) throws -> Data {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: KnownKanjiServiceTests.self).url(
                forResource: fixture,
                withExtension: "json"
            )
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let fixtureCase = try XCTUnwrap(cases.first { $0["id"] as? String == caseID })
        return try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(fixtureCase[field]),
            options: [.sortedKeys]
        )
    }
}

import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class CardSyncFeedRepositoryTests: XCTestCase {
    @MainActor
    func testPullPaginatesFromPersistedCheckpointAndAdvancesAfterEachPage() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(LocalSyncState(userID: 1, cardCheckpoint: 4))
        try container.mainContext.save()
        let firstCard = makeCard(id: "card-1", expression: "一")
        let secondCard = makeCard(id: "card-2", expression: "二")
        let firstCardID = firstCard.id
        let secondCardID = secondCard.id
        let firstBatchData = try Self.batchData([firstCard])
        let secondBatchData = try Self.batchData([secondCard])
        let feedRequests = LockedCounter()
        let requestedCheckpoints = LockedRequestPaths()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                let checkpoint = Self.queryValue("after_checkpoint", in: request)
                requestedCheckpoints.append(checkpoint ?? "missing")
                XCTAssertEqual(Self.queryValue("domain", in: request), "flashcards")
                XCTAssertEqual(Self.queryValue("resource_type", in: request), "card")
                XCTAssertEqual(Self.queryValue("per_page", in: request), "50")
                if feedRequests.next() == 1 {
                    return Self.response(
                        data: Self.feedData(entries: [(5, firstCardID, "update")], nextCheckpoint: 5, hasMore: true))
                }
                return Self.response(
                    data: Self.feedData(entries: [(6, secondCardID, "create")], nextCheckpoint: 6, hasMore: false))
            case "/api/study/cards/batch":
                XCTAssertEqual(request.httpMethod, "POST")
                let ids = try Self.batchIDs(in: request)
                return Self.response(data: ids == [firstCardID] ? firstBatchData : secondBatchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        XCTAssertEqual(result, .completed(deletedCardIdentifiers: []))
        XCTAssertEqual(requestedCheckpoints.values, ["4", "5"])
        XCTAssertEqual(try checkpoint(for: 1, in: container), 6)
        XCTAssertEqual(Set(try cards(for: 1, in: container).map(\.id)), ["card-1", "card-2"])
    }

    @MainActor
    func testOrdinaryLeanFeedMergePreservesProgressionLock() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "progression-card", expression: "local", variantGroupID: "family-1", variantStatus: "locked")
        let server = makeCard(id: local.id, expression: "server")
        let localID = local.id
        insert(local, userID: 1, in: container)
        try container.mainContext.save()
        let batchData = try Self.batchData([server], omittingProgressionMetadata: true)
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(entries: [(1, localID, "update")], nextCheckpoint: 1, hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let persisted = try XCTUnwrap(try cards(for: 1, in: container).first)
        XCTAssertEqual(persisted.promptText, "server")
        XCTAssertEqual(persisted.variantGroupId, "family-1")
        XCTAssertEqual(persisted.variantStatus, "locked")
    }

    @MainActor
    func testFeedEntryOrderControlsDeleteAndUpsertOutcome() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let restored = makeCard(id: "restored", expression: "restored-server")
        let removed = makeCard(id: "removed", expression: "removed-server")
        let restoredID = restored.id
        let removedID = removed.id
        let batchData = try Self.batchData([restored, removed])
        insert(makeCard(id: restored.id, expression: "restored-local"), userID: 1, in: container)
        insert(makeCard(id: removed.id, expression: "removed-local"), userID: 1, in: container)
        try container.mainContext.save()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(
                        entries: [
                            (1, restoredID, "delete"), (2, restoredID, "update"), (3, removedID, "update"),
                            (4, removedID, "delete"),
                        ], nextCheckpoint: 4, hasMore: false))
            case "/api/study/cards/batch":
                XCTAssertEqual(try Self.batchIDs(in: request), [restoredID, removedID])
                return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        let stored = try cards(for: 1, in: container)
        XCTAssertEqual(result, .completed(deletedCardIdentifiers: [removed.id]))
        XCTAssertEqual(stored.map(\.id), [restored.id])
        XCTAssertEqual(stored.first?.promptText, "restored-server")
        XCTAssertEqual(try checkpoint(for: 1, in: container), 4)
    }

    @MainActor
    func testLaterPageUpsertCancelsEarlierPageDeletionSignal() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "restored-across-pages", expression: "server")
        let cardID = card.id
        insert(makeCard(id: card.id, expression: "local"), userID: 1, in: container)
        try container.mainContext.save()
        let feedRequests = LockedCounter()
        let batchData = try Self.batchData([card])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                let isFirstPage = feedRequests.next() == 1
                return Self.response(
                    data: Self.feedData(
                        entries: [(isFirstPage ? 1 : 2, cardID, isFirstPage ? "delete" : "update")],
                        nextCheckpoint: isFirstPage ? 1 : 2, hasMore: isFirstPage))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)
        var committedPages: [CardSyncFeedRepository.CommittedPageChanges] = []

        let result = try await repository.pullChanges { changes in committedPages.append(changes) }

        XCTAssertEqual(result, .completed(deletedCardIdentifiers: []))
        XCTAssertEqual(committedPages.count, 2)
        XCTAssertEqual(committedPages[0].deletedCardIdentifiers, [card.id])
        XCTAssertTrue(committedPages[0].restoredCards.isEmpty)
        XCTAssertTrue(committedPages[1].deletedCardIdentifiers.isEmpty)
        XCTAssertEqual(committedPages[1].restoredCards.map(\.card.promptText), ["server"])
        XCTAssertEqual(committedPages[1].restoredCards.map(\.identifiers), [[card.id]])
        XCTAssertEqual(try cards(for: 1, in: container).map(\.id), [card.id])
        XCTAssertEqual(try checkpoint(for: 1, in: container), 2)
    }

    @MainActor
    func testSavedLocalAliasBetweenPagesInvalidatesCachedIndex() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let first = makeCard(id: "first-card", expression: "first")
        let target = makeCard(id: "server-target", expression: "server target")
        let firstID = first.id
        let targetID = target.id
        let firstData = try Self.batchData([first])
        let targetData = try Self.batchData([target])
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                let isFirstPage = feedRequests.next() == 1
                return Self.response(
                    data: Self.feedData(
                        entries: [(isFirstPage ? 1 : 2, isFirstPage ? firstID : targetID, "update")],
                        nextCheckpoint: isFirstPage ? 1 : 2, hasMore: isFirstPage))
            case "/api/study/cards/batch":
                let ids = try Self.batchIDs(in: request)
                return Self.response(data: ids == [firstID] ? firstData : targetData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext, onIndexingRecord: { _ = indexedRecords.next() })
        repository.activate(userID: 1)
        let committedPages = LockedCounter()
        var insertedAlias: LocalCardRecord?

        _ = try await repository.pullChanges { _ in
            guard committedPages.next() == 1 else { return }
            let localAlias = makeCard(id: "local-target", syncId: targetID, expression: "local target")
            let record = insert(localAlias, userID: 1, in: container)
            record.locallyUpdatedAt = Date(timeIntervalSince1970: 200)
            try! container.mainContext.save()
            insertedAlias = record
        }

        let storedRecords = try records(for: 1, in: container)
        let storedAlias = try XCTUnwrap(insertedAlias)
        let storedCard = try StorageCodec.decoder.decode(StudyCard.self, from: storedAlias.payload)
        XCTAssertEqual(storedRecords.count, 2)
        XCTAssertTrue(storedRecords.contains { $0 === storedAlias })
        XCTAssertFalse(storedRecords.contains { $0.id == targetID })
        XCTAssertEqual(storedCard.promptText, "local target")
        XCTAssertEqual(indexedRecords.current, 1)
    }

    @MainActor
    func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
    }

    @MainActor @discardableResult func insert(_ card: StudyCard, userID: Int, in container: ModelContainer)
        -> LocalCardRecord
    {
        let record = LocalCardRecord(
            card: card, userID: userID, queueIndex: 0, payload: try! StorageCodec.encoder.encode(card))
        container.mainContext.insert(record)
        return record
    }

    @MainActor
    func checkpoint(for userID: Int, in container: ModelContainer) throws -> Int64? {
        try container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first(where: { $0.userID == userID })?
            .cardCheckpoint
    }

    @MainActor
    func records(for userID: Int, in container: ModelContainer) throws -> [LocalCardRecord] {
        try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).filter { $0.userID == userID }
    }

    @MainActor
    func cards(for userID: Int, in container: ModelContainer) throws -> [StudyCard] {
        try records(for: userID, in: container).map {
            try StorageCodec.decoder.decode(StudyCard.self, from: $0.payload)
        }.sorted { $0.id < $1.id }
    }

    @MainActor
    func makeCard(
        id: String, syncId: String? = nil, expression: String, audioURL: String? = nil, queueState: String = "review",
        masteryLevel: String? = nil, variantGroupID: String? = nil, variantStatus: String? = nil,
        cardType: String = "recognition"
    ) -> StudyCard {
        var prompt: [String: JSONValue] = ["cueText": .string(expression)]
        if let audioURL { prompt["audioUrl"] = .string(audioURL) }
        return StudyCard(
            id: id, syncId: syncId, noteId: nil, cardType: cardType, prompt: .object(prompt),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: nil, introducedAt: nil, failedAt: nil, queueState: queueState, scheduler: nil,
                source: .object([:])), answerAudioSource: "missing", masteryLevel: masteryLevel,
            variantGroupId: variantGroupID, variantStatus: variantStatus, createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20))
    }

    @MainActor
    func withPresentation(_ card: StudyCard) throws -> StudyCard {
        let encoded = try StorageCodec.encoder.encode(card)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["presentation"] = Self.presentationFixture
        return try StorageCodec.decoder.decode(StudyCard.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @MainActor private static let presentationFixture: [String: Any] = [
        "version": 1,
        "front": [
            "mode": "text", "text": "projected", "ruby": NSNull(), "hint": NSNull(),
            "media": ["audio": NSNull(), "image": NSNull()], "autoplayAudio": false,
        ],
        "answer": [
            "heading": "answer", "ruby": NSNull(), "restored": NSNull(), "meaning": "meaning",
            "sentences": [
                "japanese": ["text": NSNull(), "ruby": NSNull()], "english": ["text": NSNull(), "ruby": NSNull()],
            ], "notes": [], "media": ["image": NSNull()], "audio": NSNull(), "pitchAccent": NSNull(),
        ],
    ]

    static func feedData(entries: [(Int64, String, String)], nextCheckpoint: Int64, hasMore: Bool) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "data": entries.map { checkpoint, resourceID, operation in
                ["checkpoint": checkpoint, "resource_id": resourceID, "operation": operation] as [String: Any]
            }, "meta": ["next_checkpoint": nextCheckpoint, "has_more": hasMore],
        ])
    }

    @MainActor static func batchData(_ cards: [StudyCard], omittingProgressionMetadata: Bool = false) throws -> Data {
        let values = try cards.map { card in
            var value = try XCTUnwrap(
                JSONSerialization.jsonObject(with: StorageCodec.encoder.encode(card)) as? [String: Any])
            if omittingProgressionMetadata {
                value.removeValue(forKey: "variantGroupId")
                value.removeValue(forKey: "variantStatus")
            }
            return value
        }
        return try JSONSerialization.data(withJSONObject: ["cards": values])
    }

    static func batchIDs(in request: URLRequest) throws -> [String] {
        let body = try XCTUnwrap(request.httpBody ?? requestBody(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String]])
        return try XCTUnwrap(object["ids"])
    }

    static func queryValue(_ name: String, in request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?
            .value
    }

    static func response(statusCode: Int = 200, data: Data) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: URL(string: "https://learning-os.example")!, statusCode: statusCode, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, data
        )
    }

    @MainActor
    func waitUntil(_ condition: @escaping @Sendable () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

struct InjectedPageFailure: Error {}

@MainActor func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        // Expected.
    }
}

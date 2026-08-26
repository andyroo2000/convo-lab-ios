import XCTest
@testable import ConvoLab

final class StudyCardCatalogRepositoryTests: XCTestCase {
    func testUnknownLearningItemStageStatusDecodesSafely() throws {
        let status = try JSONDecoder().decode(
            StudyLearningItemStageStatus.self,
            from: Data(#""future-stage""#.utf8)
        )

        XCTAssertEqual(status, .unknown)
    }

    @MainActor
    func testRequestsPreserveCatalogCompatibilityContract() async throws {
        let queueItem = makeQueueItem(id: "queue-card")
        let queueResponse = try StorageCodec.encoder.encode(
            StudyNewCardQueueResponse(
                items: [queueItem],
                total: 1,
                limit: 100,
                nextCursor: nil
            )
        )
        let card = makeCard(id: "library-card")
        let cardResponse = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [card], limit: 50, nextCursor: nil)
        )
        let learningItem = makeLearningItem(id: "path:animals")
        let learningItemResponse = try StorageCodec.encoder.encode(
            StudyLearningItemListResponse(
                items: [learningItem],
                limit: 20,
                nextCursor: nil
            )
        )
        let cohortResponse = try StorageCodec.encoder.encode(
            StudyIntroductionCohort(
                id: "01K00000000000000000000000",
                sourceKind: "lesson_followup",
                label: "iTalki 8/25",
                priorityUntil: Date(timeIntervalSince1970: 1_777_680_000),
                cards: [card],
                createdAt: Date(timeIntervalSince1970: 1_777_075_200),
                updatedAt: Date(timeIntervalSince1970: 1_777_075_200)
            )
        )
        CatalogMockURLProtocol.handler = { request in
            let data: Data
            switch (request.url?.path, request.url?.query, request.httpMethod) {
            case ("/api/study/new-queue", "limit=100", "GET"):
                data = queueResponse
            case ("/api/study/new-queue", "cursor=queue-next&limit=100", "GET"):
                data = queueResponse
            case ("/api/study/cards", "per_page=50&q=%E7%8C%AB", "GET"):
                data = cardResponse
            case ("/api/study/cards", "cursor=card-next&per_page=50&q=%E7%8C%AB", "GET"):
                data = cardResponse
            case ("/api/study/learning-items", "per_page=20&q=%E7%8C%AB", "GET"):
                data = learningItemResponse
            case (
                "/api/study/learning-items",
                "cursor=path-next&per_page=20&q=%E7%8C%AB",
                "GET"
            ):
                data = learningItemResponse
            case ("/api/study/new-queue/reorder", nil, "POST"):
                let body = try JSONSerialization.jsonObject(with: requestBody(request))
                    as? [String: [String]]
                XCTAssertEqual(body?["cardIds"], ["second", "first"])
                data = queueResponse
            case ("/api/study/introduction-cohorts/lesson-followup", nil, "POST"):
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody(request))
                        as? [String: Any]
                )
                XCTAssertEqual(body["cohortId"] as? String, "01K00000000000000000000000")
                XCTAssertEqual(body["cardIds"] as? [String], ["first", "second"])
                XCTAssertEqual(body["label"] as? String, "iTalki 8/25")
                data = cohortResponse
            default:
                XCTFail("Unexpected catalog request: \(request.url?.absoluteString ?? "nil")")
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogMockURLProtocol.self]
        let repository = StudyCardCatalogRepository(
            api: APIClient(
                baseURL: URL(string: "https://learning-os.example")!,
                session: URLSession(configuration: configuration)
            )
        )

        _ = try await repository.newCardQueuePage()
        _ = try await repository.newCardQueuePage(after: "queue-next")
        _ = try await repository.cardPage(matching: "猫")
        _ = try await repository.cardPage(matching: "猫", after: "card-next")
        _ = try await repository.learningItemPage(matching: "猫")
        _ = try await repository.learningItemPage(matching: "猫", after: "path-next")
        _ = try await repository.reorderNewCards(["second", "first"])
        let cohort = try await repository.createLessonFollowupCohort(
            id: "01K00000000000000000000000",
            cardIDs: ["first", "second"],
            label: "iTalki 8/25"
        )
        XCTAssertEqual(cohort.sourceKind, "lesson_followup")
    }

    @MainActor
    func testPageMergesDeduplicateNormalizedIDsAcrossAndWithinPages() {
        let existingCard = makeCard(id: "CARD")
        let newCard = makeCard(id: "new-card")
        let cards = StudyCardCatalogRepository.appendingUniqueCards(
            [makeCard(id: "card"), newCard, makeCard(id: "NEW-CARD")],
            to: [existingCard]
        )
        XCTAssertEqual(cards.map(\.id), [existingCard.id, newCard.id])

        let existingQueueItem = makeQueueItem(id: "QUEUE")
        let newQueueItem = makeQueueItem(id: "new-queue")
        let queue = StudyCardCatalogRepository.appendingUniqueQueueItems(
            [makeQueueItem(id: "queue"), newQueueItem, makeQueueItem(id: "NEW-QUEUE")],
            to: [existingQueueItem]
        )
        XCTAssertEqual(queue.map(\.id), [existingQueueItem.id, newQueueItem.id])

        let existingLearningItem = makeLearningItem(id: "PATH:animals")
        let newLearningItem = makeLearningItem(id: "path:places")
        let learningItems = StudyCardCatalogRepository.appendingUniqueLearningItems(
            [makeLearningItem(id: "path:ANIMALS"), newLearningItem],
            to: [existingLearningItem]
        )
        XCTAssertEqual(learningItems.map(\.id), [existingLearningItem.id, newLearningItem.id])

        let older = makeCard(id: "older", createdAt: Date(timeIntervalSince1970: 10))
        let replacement = makeCard(id: "card", createdAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(
            StudyCardCatalogRepository.cards([existingCard, older], matching: "older").map(\.id),
            [older.id]
        )
        XCTAssertEqual(
            StudyCardCatalogRepository.upserting(
                replacement,
                into: [older, existingCard],
                matching: ""
            ).map(\.id),
            [replacement.id, older.id]
        )
        XCTAssertEqual(
            StudyCardCatalogRepository.upserting(
                replacement,
                into: [existingCard],
                matching: "no match"
            ),
            []
        )

        let localFallback = makeCard(id: "local-card", syncId: "server-card")
        let fallbackItems = StudyCardCatalogRepository.standaloneLearningItems(
            from: [localFallback],
            matching: "LOCAL-CARD"
        )
        XCTAssertEqual(fallbackItems.map(\.id), ["card:local-card"])
        XCTAssertNil(fallbackItems.first?.groupId)
        XCTAssertEqual(fallbackItems.first?.representativeCard.syncId, "server-card")
    }

    @MainActor
    func testCardMergesDeduplicateLocalAndServerAliases() {
        let local = makeCard(id: "local-id", syncId: "server-id")
        let canonical = makeCard(id: "SERVER-ID")

        XCTAssertEqual(
            StudyCardCatalogRepository.appendingUniqueCards(
                [canonical],
                to: [local]
            ).map(\.id),
            ["local-id"]
        )
        XCTAssertEqual(
            StudyCardCatalogRepository.upserting(
                canonical,
                into: [local],
                matching: ""
            ).map(\.id),
            ["SERVER-ID"]
        )
    }

    @MainActor
    private func makeCard(
        id: String,
        syncId: String? = nil,
        createdAt: Date = .now
    ) -> StudyCard {
        StudyCard(
            id: id,
            syncId: syncId,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(id)]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "review",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: createdAt,
            updatedAt: .now
        )
    }

    @MainActor
    private func makeQueueItem(id: String) -> StudyNewCardQueueItem {
        StudyNewCardQueueItem(
            id: id,
            noteId: id,
            cardType: "recognition",
            displayText: id,
            meaning: "meaning",
            queuePosition: 1,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @MainActor
    private func makeLearningItem(id: String) -> StudyLearningItem {
        let card = StudyLearningItemCard(
            id: "card-id",
            syncId: "sync-id",
            noteId: nil,
            cardType: "recognition",
            displayText: "猫",
            meaning: "cat",
            variantKind: "sentence_audio_recognition"
        )
        return StudyLearningItem(
            id: id,
            groupId: "animals",
            representativeCard: card,
            currentStageNumber: 1,
            stageCount: 2,
            cardCount: 2,
            retiredStageCount: 0,
            transferDemonstrated: false,
            stages: [
                StudyLearningItemStage(
                    number: 1,
                    status: .available,
                    cardCount: 1,
                    representativeCard: card,
                    cards: [card]
                ),
            ]
        )
    }
}

final class CatalogMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

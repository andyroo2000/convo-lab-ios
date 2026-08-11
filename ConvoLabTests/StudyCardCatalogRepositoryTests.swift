import XCTest
@testable import ConvoLab

final class StudyCardCatalogRepositoryTests: XCTestCase {
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
            case ("/api/study/new-queue/reorder", nil, "POST"):
                let body = try JSONSerialization.jsonObject(with: requestBody(request))
                    as? [String: [String]]
                XCTAssertEqual(body?["cardIds"], ["second", "first"])
                data = queueResponse
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
        _ = try await repository.reorderNewCards(["second", "first"])
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
    }

    @MainActor
    private func makeCard(id: String, createdAt: Date = .now) -> StudyCard {
        StudyCard(
            id: id,
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

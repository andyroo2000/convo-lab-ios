import Foundation
import SwiftData
@testable import ConvoLab

@MainActor
final class SyncPerformanceFixture {
    let cardCount: Int
    let activeCount: Int
    let reserveCount: Int
    let userID = Int.random(in: 1_000_000...Int.max)
    let directory: URL
    let host = "sync-performance-\(UUID().uuidString.lowercased()).invalid"
    let container: ModelContainer
    let api: APIClient
    let session: URLSession
    let mediaCache: MediaCache
    let store: StudyStore
    let initialActivationMS: Double
    let transport: SyncPerformanceTransport
    private(set) var expectedCards: [StudyCard]
    private(set) var expectedCheckpoint: Int64
    private(set) var deletedIDs: Set<String> = []
    private var feedEntries: [SyncPerformanceTransport.Entry]

    init(cardCount: Int, activeCount: Int, reserveCount: Int) throws {
        self.cardCount = cardCount
        self.activeCount = activeCount
        self.reserveCount = reserveCount
        directory = FileManager.default.temporaryDirectory.appending(
            path: "SyncPerformance-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try Persistence.makeContainer(storeURL: directory.appending(path: "benchmark.store"))
        expectedCards = (0..<cardCount).map { Self.card(index: $0, activeCount: activeCount) }
        feedEntries = expectedCards.enumerated().map {
            .init(checkpoint: Int64($0.offset + 1), resource_id: $0.element.id, operation: "create")
        }
        expectedCheckpoint = Int64(cardCount)
        transport = try SyncPerformanceTransport(
            snapshot: Self.snapshot(
                cards: expectedCards, entries: feedEntries,
                activeCount: activeCount, reserveCount: reserveCount
            ),
            requestLatencyMS: 20,
            mediaBytesPerItem: 8_192
        )
        SyncPerformanceURLProtocol.install(transport, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncPerformanceURLProtocol.self]
        session = URLSession(configuration: configuration)
        api = APIClient(baseURL: URL(string: "https://\(host)")!, session: session)
        mediaCache = MediaCache(initialUserID: userID, api: api, context: container.mainContext)
        let activationStarted = ContinuousClock.now
        store = StudyStore(
            initialUserID: userID, api: api, context: container.mainContext, mediaCache: mediaCache
        )
        initialActivationMS = SyncPerformanceProbe.milliseconds(activationStarted.duration(to: .now))
    }

    func prepareDelta() throws {
        let updateCount = min(100, activeCount)
        for index in 0..<updateCount {
            expectedCards[index] = Self.card(index: index, activeCount: activeCount, revision: 2)
            appendEntry(id: expectedCards[index].id, operation: "update")
        }
        let replacementCount = min(10, cardCount - activeCount - reserveCount)
        let removed = Array(expectedCards.suffix(replacementCount))
        expectedCards.removeLast(replacementCount)
        for card in removed {
            deletedIDs.insert(card.id)
            appendEntry(id: card.id, operation: "delete")
        }
        for index in cardCount..<(cardCount + replacementCount) {
            let card = Self.card(index: index, activeCount: activeCount)
            expectedCards.append(card)
            appendEntry(id: card.id, operation: "create")
        }
        transport.replaceSnapshot(try Self.snapshot(
            cards: expectedCards, entries: feedEntries,
            activeCount: activeCount, reserveCount: reserveCount
        ))
    }

    func reactivateAccount() -> Double {
        store.deactivate()
        let started = ContinuousClock.now
        store.activate(userID: userID)
        return SyncPerformanceProbe.milliseconds(started.duration(to: .now))
    }

    func cleanup() throws {
        store.deactivate()
        try mediaCache.deleteLocalData(userID: userID)
        mediaCache.deactivate()
        session.invalidateAndCancel()
        SyncPerformanceURLProtocol.remove(host: host)
        // SwiftData may retain SQLite handles until process exit. Leave this
        // uniquely named temporary store for OS cleanup instead of unlinking
        // a live database (which can corrupt SQLite state in later tests).
    }

    private func appendEntry(id: String, operation: String) {
        expectedCheckpoint += 1
        feedEntries.append(.init(checkpoint: expectedCheckpoint, resource_id: id, operation: operation))
    }

    private static func snapshot(
        cards: [StudyCard], entries: [SyncPerformanceTransport.Entry],
        activeCount: Int, reserveCount: Int
    ) throws -> SyncPerformanceTransport.Snapshot {
        let encoded = try cards.map { try StorageCodec.encoder.encode($0) }
        let session = StudySession(
            overview: StudyOverview(
                dueCount: activeCount, newCount: 0, reviewCount: activeCount,
                totalCards: cards.count, newCardsPerDay: 20, newCardsAvailableToday: 0
            ),
            cards: Array(cards.prefix(activeCount))
        )
        let sessionData = Data("{\"data\":".utf8)
            + (try StorageCodec.encoder.encode(session)) + Data("}".utf8)
        var reserve = SyncPerformanceTransport.envelope(
            "cards", values: Array(encoded.dropFirst(activeCount).prefix(reserveCount))
        )
        reserve.removeLast()
        reserve.append(Data(
            #", "reserveDays":7,"generatedAt":"2026-01-01T00:00:00.000Z","horizonEndsAt":"2099-01-01T00:00:00.000Z"}"#.utf8
        ))
        return .init(
            cards: Dictionary(uniqueKeysWithValues: zip(cards.map(\.id), encoded)),
            feedEntries: entries, session: sessionData, reserve: reserve
        )
    }

    private static func card(index: Int, activeCount: Int, revision: Int = 1) -> StudyCard {
        let id = String(format: "%026d", index + 1)
        let audioID = String(format: "%026d", index * 2 + 1)
        let imageID = String(format: "%026d", index * 2 + 2)
        return StudyCard(
            id: id, noteId: nil, revision: revision, cardType: "recognition",
            prompt: .object([
                "cueText": .string("毎日、日本語の本を読んでいます。\(index) / \(revision)"),
                "audioUrl": .string("/api/study/media/\(audioID)"),
                "imageUrl": .string("/api/study/media/\(imageID)"),
            ]),
            answer: .object([
                "meaning": .string("I read Japanese books every day."),
                "reading": .string("毎日[まいにち]、日本語[にほんご]の本[ほん]を読[よ]んでいます。"),
            ]),
            state: .init(
                dueAt: Date(timeIntervalSince1970: index < activeCount ? 1_700_000_000 : 4_102_444_800),
                introducedAt: Date(timeIntervalSince1970: 1_600_000_000), failedAt: nil,
                queueState: "review", scheduler: nil, source: .object([:])
            ),
            answerAudioSource: "generated", createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(revision))
        )
    }
}

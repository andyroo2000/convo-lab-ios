import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class SyncPerformanceTests: XCTestCase {
    /// CI exercises the same path with 150 cards. Set SYNC_PERFORMANCE_LARGE=1
    /// for 2,000 cards, 100 active, 400 reserve and three independent cold runs.
    /// Results deliberately avoid wall-clock pass/fail limits on shared runners.
    @MainActor
    func testSyncEndToEndPerformanceAndCorrectness() async throws {
        let large = ProcessInfo.processInfo.environment["SYNC_PERFORMANCE_LARGE"] == "1"
        let requestedIterations = Int(ProcessInfo.processInfo.environment["SYNC_PERFORMANCE_ITERATIONS"] ?? "")
        let iterations = large ? min(10, max(1, requestedIterations ?? 3)) : 1
        var measurements: [SyncPerformanceMeasurement] = []
        for iteration in 1...iterations {
            let fixture = try SyncPerformanceFixture(
                cardCount: large ? 2_000 : 150,
                activeCount: large ? 100 : 20,
                reserveCount: large ? 400 : 50
            )
            defer { try? fixture.cleanup() }
            measurements.append(try await measureSync(fixture, phase: "cold", iteration: iteration))
            measurements.append(try await measureSync(fixture, phase: "warm", iteration: iteration))
            try fixture.prepareDelta()
            measurements.append(try await measureSync(fixture, phase: "delta", iteration: iteration))
        }
        try report(measurements)
    }

    @MainActor
    private func measureSync(
        _ fixture: SyncPerformanceFixture, phase: String, iteration: Int
    ) async throws -> SyncPerformanceMeasurement {
        let activationMS: Double? = switch phase {
        case "cold": fixture.initialActivationMS
        case "warm": fixture.reactivateAccount()
        default: nil
        }
        fixture.transport.resetTraffic()
        let probe = SyncPerformanceProbe()
        probe.start { fixture.store.cards.count == fixture.activeCount }
        await Task.yield()

        await fixture.store.synchronize()

        let timing = probe.finish(sessionIsVisible: fixture.store.cards.count == fixture.activeCount)
        let traffic = fixture.transport.trafficSnapshot()
        let records = try verifyPersistedState(fixture)
        let cached = try fixture.container.mainContext.fetch(FetchDescriptor<CachedMediaRecord>())
        try verifyReadiness(fixture, records: records, cached: cached)
        XCTAssertGreaterThan(timing.heartbeatSamples, 0)
        if phase == "warm" {
            XCTAssertEqual(traffic.mediaItems, 0, "Warm sync must not redownload cached assets.")
            XCTAssertNil(traffic.requestsByPath["/api/study/cards/batch"])
        }
        return SyncPerformanceMeasurement(
            phase: phase, iteration: iteration, cardCount: fixture.cardCount,
            activeCardCount: fixture.activeCount, reserveCardCount: fixture.reserveCount,
            mediaBytesPerItem: fixture.transport.mediaBytesPerItem,
            simulatedRequestLatencyMS: fixture.transport.requestLatencyMS,
            activationMS: activationMS, timing: timing, traffic: traffic, persistedCardCount: records.count,
            cachedMediaCount: cached.count, preparedCardCount: records.filter { $0.mediaPreparedAt != nil }.count,
            checkpoint: fixture.expectedCheckpoint
        )
    }

    @MainActor
    private func verifyPersistedState(_ fixture: SyncPerformanceFixture) throws -> [LocalCardRecord] {
        XCTAssertEqual(fixture.store.syncStatus, .idle)
        XCTAssertNotNil(fixture.store.lastSyncAt)
        XCTAssertEqual(fixture.store.cards.count, fixture.activeCount)
        XCTAssertEqual(fixture.store.libraryCards.count, fixture.cardCount)
        XCTAssertNotNil(fixture.store.offlineReserveMetadata)
        let records = try fixture.container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(Set(records.map(\.id)), Set(fixture.expectedCards.map(\.id)))
        XCTAssertTrue(fixture.deletedIDs.isDisjoint(with: records.map(\.id)))
        let expectedPrompts = Dictionary(uniqueKeysWithValues: fixture.expectedCards.map { ($0.id, $0.promptText) })
        for record in records {
            let card = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
            XCTAssertEqual(card.promptText, expectedPrompts[card.id])
        }
        let checkpoint = try XCTUnwrap(
            fixture.container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
        )
        XCTAssertEqual(checkpoint.cardCheckpoint, fixture.expectedCheckpoint)
        XCTAssertTrue(try fixture.container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty)
        return records
    }

    @MainActor
    private func verifyReadiness(
        _ fixture: SyncPerformanceFixture, records: [LocalCardRecord], cached: [CachedMediaRecord]
    ) throws {
        let requestedCards = Array(fixture.expectedCards.prefix(fixture.activeCount + fixture.reserveCount))
        let requestedIDs = Set(requestedCards.map(\.id))
        let cachedKeys = fixture.mediaCache.cachedKeys(for: requestedCards.flatMap(\.mediaURLs))
        XCTAssertEqual(cachedKeys.count, cached.count, "Every advertised cache entry must exist on disk.")
        for record in records where requestedIDs.contains(record.id) {
            let card = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
            XCTAssertEqual(card.mediaURLs.count, 2)
            let available = card.mediaURLs.allSatisfy { cachedKeys.contains(MediaCache.stableCacheKey(for: $0)) }
            XCTAssertEqual(record.mediaPreparedAt != nil, available,
                           "Metadata-only sync must never advertise missing assets as offline-ready.")
        }
    }

    private func report(_ measurements: [SyncPerformanceMeasurement]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(measurements)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "sync-performance-metrics.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SYNC_PERFORMANCE_JSON \(String(decoding: data, as: UTF8.self))")
    }
}

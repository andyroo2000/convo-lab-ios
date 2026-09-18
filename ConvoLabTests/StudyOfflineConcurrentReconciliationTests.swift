import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testLegacyRepairsRunFourAtATimeAndPublishOncePerWindow() async throws {
        let fixture = try makeLegacyRepairFixture(count: 9)
        let deferred = (0..<9).map { _ in LockedDeferredResponse() }
        let started = (0..<3).map { XCTestExpectation(description: "Window \($0) started") }
        started[0].expectedFulfillmentCount = 4
        started[1].expectedFulfillmentCount = 4
        let paths = LockedRequestPaths()
        let client = makeDeferredClient { request, completion in
            let index = Int(request.url!.lastPathComponent.replacingOccurrences(of: "legacy-", with: ""))!
            paths.append(request.url!.path)
            deferred[index].hold(completion)
            started[index / 4].fulfill()
        }
        let task = Task { try await fixture.reconcile(api: client) }
        defer { task.cancel() }
        for window in 0..<3 {
            await fulfillment(of: [started[window]], timeout: 3)
            let end = min((window + 1) * 4, 9)
            XCTAssertEqual(paths.values.count, end, "Do not start the next window before this one completes")
            for index in (window * 4)..<end {
                deferred[index].succeed(with: Self.response(data: try StorageCodec.encoder.encode(
                    fixture.cards[index].replacingVariantStatus("locked")
                )))
            }
        }
        try await task.value

        XCTAssertEqual(fixture.publicationSizes, [4, 4, 1])
        XCTAssertTrue(fixture.publishedCards.isEmpty)
        XCTAssertTrue(try fixture.records().allSatisfy { !$0.isInActiveSession })
    }

    @MainActor
    func testConcurrentRepairPublishesSuccessesWhenPeerFailsAndRetriesOnlyFailure() async throws {
        let fixture = try makeLegacyRepairFixture(count: 4)
        let payloads = try fixture.cards.map { try StorageCodec.encoder.encode($0.replacingVariantStatus("locked")) }
        let client = makeClient { request in
            let index = Int(request.url!.lastPathComponent.replacingOccurrences(of: "legacy-", with: ""))!
            if index == 2 { return Self.response(statusCode: 404, data: Data()) }
            if index == 3 { return Self.response(statusCode: 503, data: Data()) }
            return Self.response(data: payloads[index])
        }
        do {
            try await fixture.reconcile(api: client)
            XCTFail("A failed lookup must remain retryable")
        } catch APIClientError.rejected(status: 503, message: _) {}

        XCTAssertEqual(fixture.publicationSizes, [3])
        XCTAssertEqual(fixture.publishedCards.map(\.id), ["legacy-3"])
        XCTAssertEqual(try fixture.records().count, 3)
        let paths = LockedRequestPaths()
        let retry = makeClient { request in
            paths.append(request.url!.path)
            return Self.response(data: payloads[3])
        }
        try await fixture.reconcile(api: retry)
        XCTAssertEqual(paths.values, ["/api/study/cards/legacy-3"])
        XCTAssertEqual(fixture.publicationSizes, [3, 1])
        XCTAssertTrue(fixture.publishedCards.isEmpty)
    }

    @MainActor
    func testConcurrentRepairRechecksLocalChangesAcrossTheWholeWindow() async throws {
        let fixture = try makeLegacyRepairFixture(count: 4)
        let deferred = (0..<4).map { _ in LockedDeferredResponse() }
        let started = expectation(description: "All concurrent requests started")
        started.expectedFulfillmentCount = 4
        let client = makeDeferredClient { request, completion in
            let index = Int(request.url!.lastPathComponent.replacingOccurrences(of: "legacy-", with: ""))!
            deferred[index].hold(completion)
            started.fulfill()
        }
        let task = Task { try await fixture.reconcile(api: client) }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 3)
        fixture.context.insert(PendingMutation(kind: "review", userID: 1,
                                              resourceID: "legacy-0", payload: Data()))
        let edited = try XCTUnwrap(fixture.records().first { $0.id == "legacy-1" })
        edited.replacePayload(encoded: try StorageCodec.encoder.encode(fixture.cards[1].replacingVariantStatus("available")))
        try fixture.context.save()
        for index in 0..<4 {
            deferred[index].succeed(with: Self.response(data: try StorageCodec.encoder.encode(
                fixture.cards[index].replacingVariantStatus("locked")
            )))
        }
        try await task.value

        XCTAssertEqual(fixture.publicationSizes, [2])
        XCTAssertEqual(fixture.publishedCards.map(\.id), ["legacy-0", "legacy-1"])
        XCTAssertEqual(try fixture.records().filter(\.isInActiveSession).count, 2)
    }

    @MainActor
    func testConcurrentRepairDiscardsResultsAfterAccountChangeOrCancellation() async throws {
        for cancel in [false, true] {
            let fixture = try makeLegacyRepairFixture(count: 4)
            let deferred = (0..<4).map { _ in LockedDeferredResponse() }
            let started = expectation(description: "Concurrent requests started")
            started.expectedFulfillmentCount = 4
            let client = makeDeferredClient { request, completion in
                let index = Int(request.url!.lastPathComponent.replacingOccurrences(of: "legacy-", with: ""))!
                deferred[index].hold(completion)
                started.fulfill()
            }
            let task = Task { try await fixture.reconcile(api: client) }
            await fulfillment(of: [started], timeout: 3)
            if cancel { task.cancel() } else { fixture.isCurrent = false }
            for index in 0..<4 {
                deferred[index].succeed(with: Self.response(data: try StorageCodec.encoder.encode(
                    fixture.cards[index].replacingVariantStatus("locked")
                )))
            }
            do {
                try await task.value
                XCTFail("Obsolete or cancelled work must not publish")
            } catch is CancellationError {}
            XCTAssertTrue(fixture.changes.isEmpty)
            XCTAssertEqual(fixture.publishedCards.count, 4)
            XCTAssertTrue(try fixture.records().allSatisfy(\.isInActiveSession))
        }
    }

    @MainActor
    func testCanonicalRepairsStayPublishedWhenIndividualFallbackFails() async throws {
        let canonical = makeCard(id: ClientIdentifier.ulid(), expression: "canonical", dueAt: .distantPast)
        let legacy = makeCard(id: "legacy", expression: "legacy", dueAt: .distantPast)
        let fixture = try OfflineBatchFixture(cards: [canonical, legacy])
        let batchData = try StorageCodec.encoder.encode(["cards": [canonical.replacingVariantStatus("locked")]])
        let client = makeClient { request in
            if request.url?.path == "/api/study/cards/batch" { return Self.response(data: batchData) }
            return Self.response(statusCode: 503, data: Data())
        }
        do {
            try await fixture.reconcile(api: client)
            XCTFail("The individual failure should propagate after publishing canonical repairs")
        } catch APIClientError.rejected(status: 503, message: _) {}

        XCTAssertEqual(fixture.publicationSizes, [1])
        XCTAssertEqual(fixture.publishedCards.map(\.id), ["legacy"])
        XCTAssertEqual(try fixture.records().filter(\.isInActiveSession).map(\.id), ["legacy"])
    }

    @MainActor
    private func makeLegacyRepairFixture(count: Int) throws -> OfflineBatchFixture {
        try OfflineBatchFixture(cards: (0..<count).map {
            makeCard(id: "legacy-\($0)", expression: "cached", dueAt: .distantPast)
        })
    }
}

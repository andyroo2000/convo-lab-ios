import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeSynchronizationBarrierTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testSharedUploadBarrierPublishesAnalyticsBeforeHistoryCompletes() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        let pending = try fixture.seed()
        let push = Task { await fixture.coordinator.pushPending() }
        await fulfillment(of: [fixture.transport.expecting(.batch)], timeout: 2)
        let started = expectation(description: "Both synchronization callers started")
        started.expectedFulfillmentCount = 2
        let first = Task { started.fulfill(); return await fixture.coordinator.synchronize() }
        let second = Task { started.fulfill(); return await fixture.coordinator.synchronize() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(fixture.transport.count(.batch), 1)
        XCTAssertEqual(fixture.transport.count(.analytics), 0)
        XCTAssertEqual(fixture.transport.count(.history), 0)
        try fixture.transport.complete(.batch)
        await fulfillment(of: [fixture.transport.expecting(.analytics), fixture.transport.expecting(.history)], timeout: 2)
        let uploaded = await push.value
        XCTAssertEqual(uploaded?.becameStale, false)
        XCTAssertFalse(pending.syncPending)
        try fixture.transport.complete(.analytics)
        let published = expectation(description: "Chart published while history remains pending")
        let observer = Task {
            while fixture.insights.analytics == nil && !Task.isCancelled { await Task.yield() }
            if fixture.insights.analytics != nil { published.fulfill() }
        }
        await fulfillment(of: [published], timeout: 2)
        observer.cancel()
        try fixture.transport.complete(.history)
        let outcomes = await [first.value, second.value]
        XCTAssertEqual(outcomes.compactMap { $0?.shouldApply }.filter { $0 }.count, 1)
        XCTAssertEqual(fixture.transport.count(.batch), 1)
        XCTAssertEqual(fixture.transport.count(.analytics), 1)
        XCTAssertEqual(fixture.transport.count(.history), 1)
    }

    func testTokenRotationStartsANewUploadBeforeAnyRefreshRead() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        let pending = try fixture.seed()
        let old = Task { await fixture.coordinator.pushPending() }
        await fulfillment(of: [fixture.transport.expecting(.batch)], timeout: 2)
        fixture.api.setAccessToken("replacement-token")
        let synchronization = Task { await fixture.coordinator.synchronize() }
        await fulfillment(of: [fixture.transport.expecting(.batch, count: 2)], timeout: 2)
        XCTAssertEqual(try fixture.transport.request(.batch, index: 1).value(forHTTPHeaderField: "Authorization"),
                       "Bearer replacement-token")
        XCTAssertEqual(fixture.transport.count(.analytics), 0)
        XCTAssertEqual(fixture.transport.count(.history), 0)
        XCTAssertTrue(pending.syncPending)
        try fixture.transport.complete(.batch, index: 1)
        await fulfillment(of: [fixture.transport.expecting(.analytics), fixture.transport.expecting(.history)], timeout: 2)
        try fixture.transport.complete(.analytics)
        try fixture.transport.complete(.history)
        let result = await synchronization.value
        let obsolete = await old.value
        XCTAssertEqual(result?.becameStale, false)
        XCTAssertEqual(obsolete?.becameStale, true)
        XCTAssertFalse(pending.syncPending)
    }

    func testUploadCompletionRefreshesTheSelectionRequestedDuringTheUpload() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        try fixture.seed()
        let synchronization = Task { await fixture.coordinator.synchronize() }
        await fulfillment(of: [fixture.transport.expecting(.batch)], timeout: 2)
        let selection = Task { await fixture.insights.loadAnalytics(anchorDate: fixture.periods.date("2026-09-01"), range: .month) }
        await fulfillment(of: [fixture.transport.expecting(.analytics)], timeout: 2)
        try fixture.transport.complete(.batch)
        await fulfillment(of: [fixture.transport.expecting(.analytics, count: 2), fixture.transport.expecting(.history)], timeout: 2)
        let refreshed = try fixture.transport.request(.analytics, index: 1)
        let query = URLComponents(url: refreshed.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "anchorDate" }?.value, "2026-09-01")
        XCTAssertEqual(query.filter { $0.name == "ranges[]" }.compactMap(\.value), ["month"])
        try fixture.transport.complete(.analytics, index: 1)
        try fixture.transport.complete(.history)
        _ = await synchronization.value
        let resumedSelection = await selection.value
        XCTAssertTrue(resumedSelection.loaded, "The picker must join its post-upload refresh instead of falling back.")
        XCTAssertEqual(fixture.transport.count(.analytics), 2)
        XCTAssertEqual(fixture.insights.analytics?.anchorDate, "2026-09-01")
        XCTAssertNotNil(fixture.insights.analytics?.range(.month))
    }
}

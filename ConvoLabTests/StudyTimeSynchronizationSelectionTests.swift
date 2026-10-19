import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeSynchronizationSelectionTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testNewerNavigationRemainsVisibleWhenStartupAnalyticsCompletesLater() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        let synchronization = Task { await fixture.coordinator.synchronize() }
        await fulfillment(of: [fixture.transport.expecting(.analytics), fixture.transport.expecting(.history)], timeout: 2)
        let navigation = Task {
            await fixture.insights.loadAnalytics(anchorDate: fixture.periods.date("2026-09-01"), range: .month)
        }
        await fulfillment(of: [fixture.transport.expecting(.analytics, count: 2)], timeout: 2)
        try fixture.transport.complete(.analytics, index: 1)
        let selected = await navigation.value
        XCTAssertTrue(selected.loaded)
        XCTAssertEqual(fixture.insights.analytics?.anchorDate, "2026-09-01")
        try fixture.transport.complete(.analytics)
        try fixture.transport.complete(.history)
        let outcome = await synchronization.value
        XCTAssertEqual(outcome?.becameStale, false)
        XCTAssertEqual(fixture.insights.analytics?.anchorDate, "2026-09-01")
        XCTAssertNotNil(fixture.insights.cachedAnalytics(anchorDate: fixture.periods.now, range: .week))
    }

    func testSuccessfulOlderSynchronizationDoesNotClearANewerNavigationFailure() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        let store = fixture.makeStore()
        let synchronization = Task { await store.synchronize() }
        await fulfillment(of: [fixture.transport.expecting(.analytics), fixture.transport.expecting(.history)], timeout: 2)
        let navigation = Task { await store.loadAnalytics(anchorDate: fixture.periods.date("2026-09-01"), range: .month) }
        await fulfillment(of: [fixture.transport.expecting(.analytics, count: 2)], timeout: 2)
        try fixture.transport.fail(.analytics, index: 1)
        let loaded = await navigation.value
        XCTAssertFalse(loaded)
        let failure = try XCTUnwrap(store.syncErrorMessage)
        try fixture.transport.complete(.analytics)
        try fixture.transport.complete(.history)
        await synchronization.value
        XCTAssertEqual(store.syncErrorMessage, failure)
    }

    func testLocalDeletionDiscardsAnOlderSynchronizationFailure() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        let store = fixture.makeStore()
        let synchronization = Task { await store.synchronize() }
        await fulfillment(of: [fixture.transport.expecting(.analytics), fixture.transport.expecting(.history)], timeout: 2)
        try store.deleteLocalData(userID: 42)
        try fixture.transport.fail(.history, error: URLError(.timedOut))
        await synchronization.value
        XCTAssertNil(store.syncErrorMessage)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.analytics)
    }
}

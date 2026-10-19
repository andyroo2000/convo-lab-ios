import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeSynchronizationOwnershipTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testReturningToTheSameAccountCannotJoinItsObsoleteActivation() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        let oldActivation = fixture.coordinator.activationID
        let old = Task { await fixture.coordinator.synchronize() }
        await fulfillment(of: [fixture.transport.expecting(.analytics), fixture.transport.expecting(.history)], timeout: 2)
        fixture.api.setAccessToken("account-b-token")
        fixture.activate(43)
        fixture.api.setAccessToken("account-a-token")
        fixture.activate(42)
        XCTAssertNotEqual(fixture.coordinator.activationID, oldActivation)
        let current = Task { await fixture.coordinator.synchronize() }
        await fulfillment(of: [fixture.transport.expecting(.analytics, count: 2),
                              fixture.transport.expecting(.history, count: 2)], timeout: 2)
        let session = makeSession(source: .manual, clientSessionId: "new-activation-session")
        try fixture.transport.complete(.analytics, index: 1)
        try fixture.transport.complete(.history, index: 1, sessions: [session])
        let currentOutcome = await current.value
        let oldOutcome = await old.value
        XCTAssertEqual(currentOutcome?.loadedSessions?.sessions.map(\.clientSessionId), [session.clientSessionId])
        XCTAssertEqual(currentOutcome?.becameStale, false)
        XCTAssertEqual(oldOutcome?.becameStale, true)
        XCTAssertNotNil(fixture.insights.analytics)
    }

    func testCredentialChangeDuringCalendarFailureDoesNotSendTheObsoleteDelete() async throws {
        let calendar = StudyTimeSynchronizationDeferredCalendar()
        let fixture = try StudyTimeSynchronizationTestHarness(calendar: calendar)
        let record = try fixture.seed()
        record.isTombstone = true
        record.calendarEventIdentifier = "calendar-event"
        try fixture.container.mainContext.save()
        let old = Task { await fixture.coordinator.pushPending() }
        await fulfillment(of: [calendar.expecting(1)], timeout: 2)
        fixture.api.setAccessToken("replacement-token")
        let current = Task { await fixture.coordinator.pushPending() }
        await fulfillment(of: [calendar.expecting(2)], timeout: 2)
        calendar.fail(0)
        let oldOutcome = await old.value
        XCTAssertEqual(oldOutcome?.becameStale, true)
        XCTAssertEqual(fixture.transport.count(.deletion), 0)
        calendar.fail(1)
        await fulfillment(of: [fixture.transport.expecting(.deletion)], timeout: 2)
        XCTAssertEqual(try fixture.transport.request(.deletion).value(forHTTPHeaderField: "Authorization"),
                       "Bearer replacement-token")
        try fixture.transport.complete(.deletion)
        let result = await current.value
        XCTAssertEqual(result?.becameStale, false)
        XCTAssertNotNil(result?.failureMessage)
        XCTAssertTrue(record.syncPending, "The unavailable calendar event remains retryable.")
        XCTAssertEqual(record.calendarEventIdentifier, "calendar-event")
    }

    func testTokenRotationDuringDeleteCannotAcknowledgeTheNewOwner() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        let record = try fixture.seed()
        record.isTombstone = true
        try fixture.container.mainContext.save()
        let old = Task { await fixture.coordinator.pushPending() }
        await fulfillment(of: [fixture.transport.expecting(.deletion)], timeout: 2)
        fixture.api.setAccessToken("replacement-token")
        let current = Task { await fixture.coordinator.pushPending() }
        await fulfillment(of: [fixture.transport.expecting(.deletion, count: 2)], timeout: 2)
        XCTAssertTrue(record.syncPending)
        XCTAssertEqual(try fixture.transport.request(.deletion).value(forHTTPHeaderField: "Authorization"),
                       "Bearer account-a-token")
        XCTAssertEqual(try fixture.transport.request(.deletion, index: 1).value(forHTTPHeaderField: "Authorization"),
                       "Bearer replacement-token")
        try fixture.transport.complete(.deletion, index: 1)
        let result = await current.value
        let stale = await old.value
        XCTAssertEqual(result?.becameStale, false)
        XCTAssertEqual(stale?.becameStale, true)
        XCTAssertFalse(record.syncPending)
    }

    func testLocalMutationPreventsAnOlderHistoryResponseFromReplacingTheRow() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        let record = try fixture.seed(pending: false)
        let oldSession = try XCTUnwrap(record.session)
        let synchronization = Task { await fixture.coordinator.synchronize() }
        await fulfillment(of: [fixture.transport.expecting(.analytics), fixture.transport.expecting(.history)], timeout: 2)
        record.name = "Newer local edit"
        record.syncPending = true
        try fixture.container.mainContext.save()
        fixture.coordinator.markLocalMutation()
        try fixture.transport.complete(.history, sessions: [oldSession])
        let outcome = await synchronization.value
        XCTAssertEqual(outcome?.becameStale, true)
        XCTAssertNil(outcome?.loadedSessions)
        XCTAssertEqual(record.name, "Newer local edit")
        XCTAssertTrue(record.syncPending)
        XCTAssertNil(fixture.insights.analytics)
    }

    func testCompletedOutcomesBecomeInvalidBeforeApplyingAfterMutationTokenOrActivationChanges() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        let synchronization = Task { await fixture.coordinator.synchronize() }
        await fulfillment(of: [fixture.transport.expecting(.analytics), fixture.transport.expecting(.history)], timeout: 2)
        try fixture.transport.complete(.analytics)
        try fixture.transport.complete(.history)
        let completedSync = await synchronization.value
        XCTAssertTrue(fixture.coordinator.canApply(completedSync?.context))
        fixture.coordinator.markLocalMutation()
        XCTAssertFalse(fixture.coordinator.canApply(completedSync?.context))

        let completedPush = await fixture.coordinator.pushPending()
        XCTAssertTrue(fixture.coordinator.canApply(completedPush?.context))
        fixture.api.setAccessToken("replacement-token")
        XCTAssertFalse(fixture.coordinator.canApply(completedPush?.context))

        let currentPush = await fixture.coordinator.pushPending()
        XCTAssertTrue(fixture.coordinator.canApply(currentPush?.context))
        fixture.activate(43)
        fixture.activate(42)
        XCTAssertFalse(fixture.coordinator.canApply(currentPush?.context))
        XCTAssertFalse(fixture.coordinator.canApply(nil))
    }
}

@MainActor
private final class StudyTimeSynchronizationDeferredCalendar: StudyCalendarProviding {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var expectations: [Int: XCTestExpectation] = [:]
    nonisolated deinit {}

    func addEvent(title: String, start: Date, end: Date) async throws -> String { "unused" }
    func updateEvent(identifier: String, title: String, start: Date, end: Date) async throws {}

    func deleteEvent(identifier: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            expectations.removeValue(forKey: continuations.count)?.fulfill()
        }
    }

    func expecting(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Calendar deletion \(count)")
        if continuations.count >= count { expectation.fulfill() }
        else { expectations[count] = expectation }
        return expectation
    }

    func fail(_ index: Int) { continuations[index].resume(throwing: URLError(.noPermissionsToReadFile)) }
}

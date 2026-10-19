import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeUploadProjectionTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testStandaloneUploadAcknowledgementPreservesDisplayedSessionsAndActiveTimer() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        try fixture.seed("existing-session", pending: false)
        let store = fixture.makeStore()
        XCTAssertTrue(store.start(activity: .reading, source: .manual, name: "Reading now", at: fixture.periods.now))
        let recording = Task {
            try await store.recordCompleted(activity: .conversation, source: .manual, name: "Conversation",
                                            startedAt: fixture.periods.now.addingTimeInterval(-600), duration: 300,
                                            clientSessionID: "new-session")
        }
        await fulfillment(of: [fixture.transport.expecting(.batch)], timeout: 2)
        let displayedSessions = store.sessions
        let displayedActive = try XCTUnwrap(store.active)
        XCTAssertEqual(Set(displayedSessions.map(\.clientSessionId)), ["existing-session", "new-session"])
        try fixture.transport.complete(.batch)
        await fulfillment(of: [fixture.transport.expecting(.analytics)], timeout: 2)
        try fixture.transport.complete(.analytics)
        _ = try await recording.value

        XCTAssertEqual(store.sessions, displayedSessions)
        XCTAssertEqual(store.active, displayedActive)
        XCTAssertNil(store.syncErrorMessage)
        XCTAssertEqual(fixture.transport.count(.history), 0)
        let records = try fixture.container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>())
        XCTAssertFalse(try XCTUnwrap(records.first { $0.clientSessionID == "new-session" }).syncPending)
    }

    func testHistoryFailureAfterUploadKeepsAlreadyDisplayedSessionsAndActiveTimer() async throws {
        let fixture = try StudyTimeSynchronizationTestHarness()
        try fixture.seed("pending-session")
        let store = fixture.makeStore()
        XCTAssertTrue(store.start(activity: .reading, source: .manual, name: "Reading now", at: fixture.periods.now))
        let displayedSessions = store.sessions
        let displayedActive = try XCTUnwrap(store.active)
        let synchronization = Task { await store.synchronize() }
        await fulfillment(of: [fixture.transport.expecting(.batch)], timeout: 2)
        try fixture.transport.complete(.batch)
        await fulfillment(of: [fixture.transport.expecting(.history), fixture.transport.expecting(.analytics)], timeout: 2)
        try fixture.transport.fail(.history)
        try fixture.transport.complete(.analytics)
        await synchronization.value

        XCTAssertEqual(store.sessions, displayedSessions)
        XCTAssertEqual(store.active, displayedActive)
        XCTAssertNotNil(store.syncErrorMessage, "The real download failure must remain visible.")
        XCTAssertNotNil(store.analytics)
        let records = try fixture.container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>())
        XCTAssertFalse(try XCTUnwrap(records.first { $0.clientSessionID == "pending-session" }).syncPending)
    }
}

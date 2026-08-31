import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class SatoriReaderTrackingStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SatoriReaderTrackingStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testStartsUndetectedAndRecordsBothAutomationReceipts() {
        let store = SatoriReaderTrackingStore(defaults: defaults)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let stoppedAt = startedAt.addingTimeInterval(12 * 60)

        XCTAssertEqual(store.snapshot().detectionStatus, .notDetected)
        store.recordStart(at: startedAt)
        XCTAssertEqual(store.snapshot().detectionStatus, .partiallyDetected)
        store.recordStop(at: stoppedAt)

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.detectionStatus, .detected)
        XCTAssertEqual(snapshot.lastStartedAt, startedAt)
        XCTAssertEqual(snapshot.lastStoppedAt, stoppedAt)
    }

    func testCompletedSessionIsDurableAccountScopedAndAcknowledged() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let stoppedAt = startedAt.addingTimeInterval(12 * 60)
        let store = SatoriReaderTrackingStore(defaults: defaults)
        store.setActiveUserID(42)
        store.recordStart(at: startedAt)
        store.recordStop(at: stoppedAt)

        let reloaded = SatoriReaderTrackingStore(defaults: defaults)
        let session = try XCTUnwrap(reloaded.pendingSessions(userID: 42).first)
        XCTAssertEqual(session.startedAt, startedAt)
        XCTAssertEqual(session.endedAt, stoppedAt)
        XCTAssertEqual(session.duration, 12 * 60)
        XCTAssertTrue(reloaded.pendingSessions(userID: 7).isEmpty)

        reloaded.acknowledge(sessionID: session.id, userID: 42)
        XCTAssertTrue(reloaded.pendingSessions(userID: 42).isEmpty)
    }

    func testSignedOutReceiptsVerifySetupWithoutCreatingStudyTime() {
        let store = SatoriReaderTrackingStore(defaults: defaults)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.recordStart(at: startedAt)
        store.recordStop(at: startedAt.addingTimeInterval(60))

        XCTAssertEqual(store.snapshot().detectionStatus, .detected)
        XCTAssertTrue(store.pendingSessions(userID: 42).isEmpty)
    }

    func testVerificationOnlyCountsReceiptsAfterTestStarted() {
        let store = SatoriReaderTrackingStore(defaults: defaults)
        let oldStart = Date(timeIntervalSince1970: 1_700_000_000)
        let verificationStart = oldStart.addingTimeInterval(120)
        store.recordStart(at: oldStart)
        store.recordStop(at: oldStart.addingTimeInterval(60))
        store.beginVerification(at: verificationStart)

        XCTAssertEqual(store.snapshot().verificationStatus, .waiting)
        store.recordStart(at: verificationStart.addingTimeInterval(1))
        XCTAssertEqual(store.snapshot().verificationStatus, .partiallyDetected)
        store.recordStop(at: verificationStart.addingTimeInterval(61))
        XCTAssertEqual(store.snapshot().verificationStatus, .succeeded)
    }

    func testNewStartReplacesAnAbandonedOpenReceiptAndDurationIsBounded() throws {
        let store = SatoriReaderTrackingStore(defaults: defaults)
        let abandonedStart = Date(timeIntervalSince1970: 1_700_000_000)
        let currentStart = abandonedStart.addingTimeInterval(2 * 24 * 60 * 60)
        store.setActiveUserID(42)
        store.recordStart(at: abandonedStart)
        store.recordStart(at: currentStart)
        store.recordStop(at: currentStart.addingTimeInterval(2 * 24 * 60 * 60))

        let session = try XCTUnwrap(store.pendingSessions(userID: 42).first)
        XCTAssertEqual(session.startedAt, currentStart)
        XCTAssertEqual(session.duration, 24 * 60 * 60)
    }

    func testRemovingAccountClearsItsInFlightSession() {
        let store = SatoriReaderTrackingStore(defaults: defaults)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.setActiveUserID(42)
        store.recordStart(at: startedAt)

        store.removeAccountData(userID: 42)
        store.recordStop(at: startedAt.addingTimeInterval(600))

        XCTAssertTrue(store.pendingSessions(userID: 42).isEmpty)
    }
}

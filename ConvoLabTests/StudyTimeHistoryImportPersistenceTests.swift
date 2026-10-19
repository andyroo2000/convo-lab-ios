import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeHistoryImportPersistenceTests: XCTestCase {
    func testFailedSecondBatchRollsBackOnlyItsRowsAndRetryIsIdempotent() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        let remote = (0..<5).map { StudyTimeHistoryImportHarness.session($0) }
        let failing = StudyTimeHistoryImportSaver(context: fixture.context, failures: [2])
        do {
            _ = try await fixture.importer(saver: failing).mergeAndLoad(remote, userID: 42, canContinue: { true })
            XCTFail("The injected second-batch save must fail.")
        } catch StudyTimeHistoryImportSaver.Failure.injected {}
        XCTAssertEqual(failing.calls, 2)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try fixture.persistedIDs(), ["row-000", "row-001"])
        XCTAssertEqual(try fixture.records().map(\.clientSessionID).sorted(), ["row-000", "row-001"])

        let retrySaver = StudyTimeHistoryImportSaver(context: fixture.context)
        let retry = try await fixture.importer(saver: retrySaver).mergeAndLoad(remote, userID: 42, canContinue: { true })
        XCTAssertEqual(retry.sessions, remote.reversed().map { $0 })
        XCTAssertEqual(try fixture.persistedIDs(), remote.map(\.clientSessionId))
        XCTAssertEqual(retrySaver.calls, 2, "The already committed first batch needs no write.")
        let warmSaver = StudyTimeHistoryImportSaver(context: fixture.context)
        let warm = try await fixture.importer(saver: warmSaver).mergeAndLoad(remote, userID: 42, canContinue: { true })
        XCTAssertEqual(warm.sessions, retry.sessions)
        XCTAssertEqual(warmSaver.calls, 0)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testPendingTombstoneActiveAndOtherAccountRowsArePreserved() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        let pending = StudyTimeHistoryImportHarness.session(0, name: "Local pending edit")
        let deleted = StudyTimeHistoryImportHarness.session(1)
        let otherAccount = StudyTimeHistoryImportHarness.session(2, name: "Other account")
        fixture.seed(pending, pending: true)
        fixture.seed(deleted, tombstone: true)
        fixture.seed(otherAccount, userID: 43)
        fixture.seedActive("active-session", at: pending.startedAt.addingTimeInterval(120))
        try fixture.context.save()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        let remote = (0..<4).map { StudyTimeHistoryImportHarness.session($0, name: "Remote \($0)") }
        let loaded = try await fixture.importer(saver: saver).mergeAndLoad(remote, userID: 42, canContinue: { true })
        XCTAssertEqual(loaded.sessions.map(\.clientSessionId), ["row-003", "row-002", "row-000"])
        XCTAssertEqual(loaded.sessions.last, pending)
        XCTAssertEqual(loaded.active?.clientSessionID, "active-session")
        let records = try fixture.records()
        XCTAssertTrue(try XCTUnwrap(records.first { $0.clientSessionID == "row-000" }).syncPending)
        XCTAssertTrue(try XCTUnwrap(records.first { $0.clientSessionID == "row-001" }).isTombstone)
        XCTAssertNil(try XCTUnwrap(records.first { $0.clientSessionID == "active-session" }).endedAt)
        XCTAssertEqual(try fixture.persistedName("row-002", userID: 43), otherAccount.name)
        XCTAssertEqual(try fixture.persistedIDs(userID: 43), ["row-002"])
    }

    func testDuplicateRemoteIDsAcrossBatchesKeepTheLastValueWithoutDuplicateRows() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        let first = StudyTimeHistoryImportHarness.session(0, name: "First")
        let last = StudyTimeHistoryImportHarness.session(0, name: "Last")
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        let loaded = try await fixture.importer(saver: saver).mergeAndLoad(
            [first, StudyTimeHistoryImportHarness.session(1), last], userID: 42, canContinue: { true }
        )
        XCTAssertEqual(try fixture.persistedIDs(), ["row-000", "row-001"])
        XCTAssertEqual(loaded.sessions.last, last)
        XCTAssertEqual(saver.calls, 2)
    }

    func testPreexistingDirtyStateIsNeitherCommittedNorRolledBack() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        fixture.seed(StudyTimeHistoryImportHarness.session(0, name: "Persisted"))
        try fixture.context.save()
        try XCTUnwrap(fixture.records().first).name = "Unsaved edit"
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        do {
            _ = try await fixture.importer(saver: saver).mergeAndLoad(
                [StudyTimeHistoryImportHarness.session(1)], userID: 42, canContinue: { true }
            )
            XCTFail("A history import must not own another operation's dirty changes.")
        } catch is CancellationError {}
        XCTAssertEqual(saver.calls, 0)
        XCTAssertTrue(fixture.context.hasChanges)
        XCTAssertEqual(try fixture.records().first?.name, "Unsaved edit")
        XCTAssertEqual(try fixture.persistedName("row-000"), "Persisted")
        XCTAssertEqual(try fixture.persistedIDs(), ["row-000"])
        fixture.context.rollback()
    }
}

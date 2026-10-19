import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeHistoryImportInterruptionTests: XCTestCase {
    func testInactiveOwnershipDoesNotStartImporting() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        var yields = 0
        let importer = fixture.importer(saver: saver, yieldControl: { yields += 1 })
        do {
            _ = try await importer.mergeAndLoad([StudyTimeHistoryImportHarness.session(0)], userID: 42,
                                               canContinue: { false })
            XCTFail("An inactive account must not start an import.")
        } catch is CancellationError {}
        XCTAssertEqual(saver.calls, 0)
        XCTAssertEqual(yields, 0)
        XCTAssertEqual(try fixture.persistedIDs(), [])
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testReactivatedSameAccountCannotContinueAnOlderImport() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        let originalActivation = UUID()
        var currentActivation = originalActivation
        let importer = fixture.importer(saver: saver, yieldControl: { currentActivation = UUID() })
        do {
            _ = try await importer.mergeAndLoad((0..<5).map { StudyTimeHistoryImportHarness.session($0) }, userID: 42,
                                               canContinue: { currentActivation == originalActivation })
            XCTFail("The same account with a new activation must not resume old work.")
        } catch is CancellationError {}
        XCTAssertEqual(saver.calls, 1)
        XCTAssertEqual(try fixture.persistedIDs(), ["row-000", "row-001"])
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testNewerSavedMutationStopsRemainingBatchesAndPreservesLocalEdit() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        var currentGeneration = 0
        let importer = fixture.importer(saver: saver, yieldControl: {
            fixture.expectSuccessfulMutation { try fixture.savePendingEdit("row-000", name: "New local edit") }
            currentGeneration += 1
        })
        do {
            _ = try await importer.mergeAndLoad((0..<5).map { StudyTimeHistoryImportHarness.session($0) }, userID: 42,
                                               canContinue: { currentGeneration == 0 })
            XCTFail("A newer local mutation must invalidate the old history import.")
        } catch is CancellationError {}
        XCTAssertEqual(saver.calls, 1)
        XCTAssertEqual(try fixture.persistedIDs(), ["row-000", "row-001"])
        XCTAssertEqual(try fixture.persistedName("row-000"), "New local edit")
        XCTAssertTrue(try XCTUnwrap(fixture.records().first { $0.clientSessionID == "row-000" }).syncPending)
    }

    func testDeletingLocalDataAtYieldDoesNotResurrectRemainingRemoteRows() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        fixture.seed(StudyTimeHistoryImportHarness.session(9), userID: 43)
        try fixture.context.save()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        var ownsImport = true
        let importer = fixture.importer(saver: saver, yieldControl: {
            fixture.expectSuccessfulMutation { try fixture.deleteRecords() }
            ownsImport = false
        })
        do {
            _ = try await importer.mergeAndLoad((0..<5).map { StudyTimeHistoryImportHarness.session($0) }, userID: 42,
                                               canContinue: { ownsImport })
            XCTFail("Deleting local data must invalidate the remaining import.")
        } catch is CancellationError {}
        XCTAssertEqual(saver.calls, 1)
        XCTAssertEqual(try fixture.persistedIDs(), [])
        XCTAssertEqual(try fixture.persistedIDs(userID: 43), ["row-009"])
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testTaskCancellationAfterCommittedBatchStopsBeforeNextBatch() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        let gate = StudyTimeHistoryImportGate()
        let importer = fixture.importer(saver: saver, yieldControl: { await gate.pause() })
        let task = Task {
            try await importer.mergeAndLoad((0..<5).map { StudyTimeHistoryImportHarness.session($0) }, userID: 42,
                                            canContinue: { true })
        }
        await fulfillment(of: [gate.reached], timeout: 2)
        task.cancel()
        gate.release()
        do {
            _ = try await task.value
            XCTFail("Task cancellation must stop the next chunk even while ownership is otherwise valid.")
        } catch is CancellationError {}
        XCTAssertEqual(saver.calls, 1)
        XCTAssertEqual(try fixture.persistedIDs(), ["row-000", "row-001"])
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testLaterBatchRefetchesPendingFlagsChangedDuringYield() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        fixture.seed(StudyTimeHistoryImportHarness.session(2, name: "Previously synced"))
        try fixture.context.save()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        var didEdit = false
        let importer = fixture.importer(saver: saver, yieldControl: {
            guard !didEdit else { return }
            didEdit = true
            fixture.expectSuccessfulMutation {
                try fixture.savePendingEdit("row-002", name: "Pending while import yields")
            }
        })
        let loaded = try await importer.mergeAndLoad((0..<4).map { StudyTimeHistoryImportHarness.session($0) },
                                                      userID: 42, canContinue: { true })
        XCTAssertEqual(loaded.sessions.first { $0.clientSessionId == "row-002" }?.name, "Pending while import yields")
        XCTAssertEqual(try fixture.persistedName("row-002"), "Pending while import yields")
        XCTAssertTrue(try XCTUnwrap(fixture.records().first { $0.clientSessionID == "row-002" }).syncPending)
        XCTAssertEqual(loaded.sessions.count, 4)
    }
}

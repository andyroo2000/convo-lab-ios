import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeHistoryImportProjectionTests: XCTestCase {
    func testProjectionPaginatesEqualDatesAndSelectsNewestActiveAcrossIdentifierPages() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        let completed = (0..<7).map { StudyTimeHistoryImportHarness.session($0) }
        completed.forEach { fixture.seed($0) }
        let date = try XCTUnwrap(completed.first).startedAt
        fixture.seedActive("z-active-older", at: date.addingTimeInterval(-60))
        fixture.seedActive("a-active-newest", at: date.addingTimeInterval(120))
        fixture.seed(StudyTimeHistoryImportHarness.session(9), tombstone: true)
        fixture.seed(StudyTimeHistoryImportHarness.session(8), userID: 43)
        try fixture.context.save()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        var yields = 0
        let importer = fixture.importer(saver: saver, yieldControl: { yields += 1 })
        let loaded = try await importer.mergeAndLoad([], userID: 42, canContinue: { true })
        XCTAssertEqual(loaded.sessions, completed.reversed().map { $0 })
        XCTAssertEqual(loaded.active?.clientSessionID, "a-active-newest")
        XCTAssertEqual(yields, 5, "Ten owned records require five full pages, then an empty terminal page.")
        XCTAssertEqual(saver.calls, 0)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testProjectionOrdersByDateBeforeIdentifierAcrossDifferentPageSizes() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        let date = StudyTimeHistoryImportHarness.session(0).startedAt
        let newest = StudyTimeHistoryImportHarness.session(0, start: date.addingTimeInterval(120))
        let sameDateLow = StudyTimeHistoryImportHarness.session(1, start: date)
        let sameDateHigh = StudyTimeHistoryImportHarness.session(8, start: date)
        let oldest = StudyTimeHistoryImportHarness.session(9, start: date.addingTimeInterval(-120))
        [oldest, sameDateLow, newest, sameDateHigh].forEach { fixture.seed($0) }
        try fixture.context.save()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        for batchSize in [2, 3] {
            let loaded = try await fixture.importer(saver: saver, batchSize: batchSize)
                .mergeAndLoad([], userID: 42, canContinue: { true })
            XCTAssertEqual(loaded.sessions, [newest, sameDateHigh, sameDateLow, oldest])
            XCTAssertNil(loaded.active)
        }
        XCTAssertEqual(saver.calls, 0)
    }

    func testCompletedProjectionRechecksOwnershipBeforeReturningSortedValues() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        fixture.seed(StudyTimeHistoryImportHarness.session(0))
        try fixture.context.save()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        var ownershipChecks = 0
        do {
            _ = try await fixture.importer(saver: saver).mergeAndLoad([], userID: 42, canContinue: {
                ownershipChecks += 1
                return ownershipChecks == 1
            })
            XCTFail("Ownership valid for the final page must be checked again after asynchronous sorting.")
        } catch is CancellationError {}
        XCTAssertEqual(ownershipChecks, 2)
        XCTAssertEqual(saver.calls, 0)
        XCTAssertEqual(try fixture.persistedIDs(), ["row-000"])
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testDiskProjectionPreservesVariableWidthIdentifiersAcrossPages() async throws {
        try await assertVariableWidthProjection(inMemory: false)
    }

    func testInMemoryProjectionPreservesVariableWidthIdentifiersAcrossPages() async throws {
        try await assertVariableWidthProjection(inMemory: true)
    }

    private func assertVariableWidthProjection(inMemory: Bool) async throws {
        let fixture = try StudyTimeHistoryImportHarness(inMemory: inMemory)
        let remote = (0..<130).map { index in
            let prefix = index.isMultiple(of: 3) ? "Client" : "client"
            return StudyTimeHistoryImportHarness.session(index, clientSessionID: "\(prefix)-\(index)")
        }
        remote.forEach { fixture.seed($0) }
        try fixture.context.save()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        let loaded = try await fixture.importer(saver: saver, batchSize: 17)
            .mergeAndLoad([], userID: 42, canContinue: { true })
        XCTAssertEqual(loaded.sessions.count, remote.count)
        XCTAssertEqual(Set(loaded.sessions.map(\.clientSessionId)), Set(remote.map(\.clientSessionId)))
        XCTAssertEqual(loaded.sessions, remote.sorted { $0.clientSessionId > $1.clientSessionId })
        XCTAssertEqual(saver.calls, 0)
    }

    func testDeletionDuringProjectionRejectsPartialResultsWithoutRecreatingData() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        (0..<5).forEach { fixture.seed(StudyTimeHistoryImportHarness.session($0)) }
        try fixture.context.save()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        var ownsImport = true
        let importer = fixture.importer(saver: saver, yieldControl: {
            fixture.expectSuccessfulMutation { try fixture.deleteRecords() }
            ownsImport = false
        })
        do {
            _ = try await importer.mergeAndLoad([], userID: 42, canContinue: { ownsImport })
            XCTFail("The partial projection must not escape after local data is deleted.")
        } catch is CancellationError {}
        XCTAssertEqual(try fixture.persistedIDs(), [])
        XCTAssertEqual(saver.calls, 0)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testUnsavedEditDuringProjectionIsNeitherSavedNorRolledBack() async throws {
        let fixture = try StudyTimeHistoryImportHarness()
        (0..<5).forEach { fixture.seed(StudyTimeHistoryImportHarness.session($0, name: "Persisted")) }
        try fixture.context.save()
        let saver = StudyTimeHistoryImportSaver(context: fixture.context)
        let importer = fixture.importer(saver: saver, yieldControl: {
            fixture.expectSuccessfulMutation {
                try fixture.changeName("row-000", to: "Uncommitted foreground edit")
            }
        })
        do {
            _ = try await importer.mergeAndLoad([], userID: 42, canContinue: { true })
            XCTFail("A projection must stop before consuming another operation's unfinished mutation.")
        } catch is CancellationError {}
        XCTAssertTrue(fixture.context.hasChanges)
        XCTAssertEqual(try fixture.records().first { $0.clientSessionID == "row-000" }?.name,
                       "Uncommitted foreground edit")
        XCTAssertEqual(try fixture.persistedName("row-000"), "Persisted")
        XCTAssertEqual(saver.calls, 0)
        fixture.context.rollback()
    }
}

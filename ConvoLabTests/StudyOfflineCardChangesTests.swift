import Foundation
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testGroupedOfflineChangesPreserveOrderAliasesAndPerCardStudyDates() async throws {
        let now = Date.now
        let dueAt = now.addingTimeInterval(600)
        let existing = [
            makeCard(id: "unaffected", expression: "keep", dueAt: .distantPast),
            makeCard(id: "local", syncId: "SERVER", expression: "old", dueAt: .distantPast),
            makeCard(id: "deleted", expression: "delete", dueAt: .distantPast),
            makeCard(id: "rescheduled", expression: "later", dueAt: .distantPast),
        ]
        let updated = makeCard(id: "local", syncId: "server", expression: "updated", dueAt: dueAt)
        let later = makeCard(id: "rescheduled", expression: "later", dueAt: dueAt)
        let update = StudyOfflineCardChanges([
            .init(identifiers: ["server"], card: updated, evaluatedAt: dueAt),
            .init(identifiers: ["deleted"], card: nil, evaluatedAt: now),
            .init(identifiers: ["rescheduled"], card: later, evaluatedAt: now),
        ])

        XCTAssertEqual(update.applying(to: existing).map(\.id), ["unaffected", "local", "rescheduled"])
        let studying = update.applying(to: existing, studying: true)
        XCTAssertEqual(studying.map(\.id), ["unaffected", "local"])
        XCTAssertEqual(studying.last?.promptText, "updated")
    }
}

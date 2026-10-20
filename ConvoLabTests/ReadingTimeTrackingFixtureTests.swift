import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
struct ReadingTimeTrackingFixture {
    let container: ModelContainer
    let store: StudyTimeStore
    let tracker = ReadingTimeTracker()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func records() throws -> [LocalStudyActivitySession] {
        try container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>())
            .sorted { $0.startedAt < $1.startedAt }
    }

    func update(_ title: String?, after seconds: TimeInterval = 0) {
        tracker.update(title: title, store: store, at: startedAt.addingTimeInterval(seconds))
    }
}

@MainActor
extension StudyActivitySessionTests {
    func makeReadingTimeFixture(
        failingSaveAttempts: Set<Int> = []
    ) throws -> ReadingTimeTrackingFixture {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let saves = DeterministicStudyTimeSaves(
            context: container.mainContext,
            failingAttempts: failingSaveAttempts
        )
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext,
            contextSaver: saves,
            snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        store.activate(userID: 42)
        // Match the suite's existing SwiftData lifetime workaround. Unstructured
        // analytics refreshes can finish after an individual test returns.
        retainSaveFixtures(container, store, saves)
        return ReadingTimeTrackingFixture(container: container, store: store)
    }
}

import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testLeavingForegroundKeepsBackgroundAudioTracking() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.activate(userID: 42)
        store.start(
            activity: .dailyAudio,
            source: .automatic,
            name: "Daily Audio",
            at: startedAt
        )

        store.stopForegroundAutomaticTracking(at: startedAt.addingTimeInterval(90))

        XCTAssertEqual(store.active?.activity, .dailyAudio)
        XCTAssertEqual(store.active?.startedAt, startedAt)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>()).first
        )
        XCTAssertNil(record.endedAt)
        XCTAssertFalse(record.syncPending)

        await store.deactivate(at: startedAt.addingTimeInterval(90))
    }
}

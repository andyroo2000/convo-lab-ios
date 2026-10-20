import Foundation
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testReadingTimePreservesManualReadingWithTheSameTitle() async throws {
        let fixture = try makeReadingTimeFixture()
        fixture.store.start(activity: .reading, source: .manual, name: "Chapter", at: fixture.startedAt)
        let manual = fixture.store.active

        fixture.update("Chapter", after: 10)
        fixture.update(nil, after: 30)

        XCTAssertEqual(fixture.store.active, manual)
        XCTAssertEqual(try fixture.records().count, 1)
        XCTAssertNil(try fixture.records().first?.endedAt)
        await fixture.store.deactivate(at: fixture.startedAt.addingTimeInterval(60))
    }

    func testReadingTimeOldReaderCannotStopAnotherReadingWithTheSameTitle() async throws {
        let fixture = try makeReadingTimeFixture()
        fixture.update("Chapter")
        let firstID = try XCTUnwrap(fixture.store.active?.clientSessionID)
        let nextReader = ReadingTimeTracker()
        nextReader.update(title: "Chapter", store: fixture.store, at: fixture.startedAt.addingTimeInterval(60))
        let secondID = try XCTUnwrap(fixture.store.active?.clientSessionID)

        // A late page/load callback from the old reader must not reclaim an
        // interval while SwiftUI is still completing its disappearance.
        fixture.update("Chapter", after: 65)
        XCTAssertEqual(fixture.store.active?.clientSessionID, secondID)
        fixture.update(nil, after: 70)

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(fixture.store.active?.clientSessionID, secondID)
        XCTAssertEqual(try fixture.records().first?.durationMs, 60_000)
        nextReader.update(title: nil, store: fixture.store, at: fixture.startedAt.addingTimeInterval(120))
        XCTAssertEqual(try fixture.records().map(\.durationMs), [60_000, 60_000])
        await fixture.store.deactivate()
    }

    func testReadingTimeCleanupDoesNotStopAReplacementActivity() async throws {
        let fixture = try makeReadingTimeFixture()
        fixture.update("Chapter")
        fixture.store.start(
            activity: .dailyAudio,
            source: .automatic,
            name: "Daily Audio",
            at: fixture.startedAt.addingTimeInterval(90)
        )
        let replacement = fixture.store.active

        fixture.update("Chapter", after: 95)
        XCTAssertEqual(fixture.store.active, replacement)
        fixture.update(nil, after: 100)

        XCTAssertEqual(fixture.store.active, replacement)
        XCTAssertEqual(try fixture.records().first?.durationMs, 90_000)
        await fixture.store.deactivate(at: fixture.startedAt.addingTimeInterval(120))
    }

    func testReadingTimeOldAccountCleanupDoesNotStopTheNewAccountSession() async throws {
        let fixture = try makeReadingTimeFixture()
        fixture.update("Chapter")
        await fixture.store.deactivate(at: fixture.startedAt.addingTimeInterval(60))
        fixture.store.activate(userID: 84)
        let newReader = ReadingTimeTracker()
        newReader.update(title: "Chapter", store: fixture.store, at: fixture.startedAt.addingTimeInterval(90))
        let newSessionID = fixture.store.active?.clientSessionID

        fixture.update(nil, after: 100)

        XCTAssertEqual(fixture.store.active?.clientSessionID, newSessionID)
        let records = try fixture.records()
        XCTAssertEqual(records.map(\.userID), [42, 84])
        XCTAssertEqual(records[0].durationMs, 60_000)
        XCTAssertNil(records[1].endedAt)
        await fixture.store.deactivate(at: fixture.startedAt.addingTimeInterval(120))
    }
}

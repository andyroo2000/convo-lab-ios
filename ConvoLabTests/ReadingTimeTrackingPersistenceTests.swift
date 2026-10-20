import Foundation
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testReadingTimeLimitsLongTitlesByUnicodeCodePointForTheAPI() async throws {
        let fixture = try makeReadingTimeFixture()
        let title = String(repeating: "👩🏽‍💻", count: 50) + "日本語"

        fixture.update(title)

        let name = try XCTUnwrap(fixture.store.active?.name)
        XCTAssertEqual(name.unicodeScalars.count, 120)
        XCTAssertEqual(name, String(title.unicodeScalars.prefix(120)))
        XCTAssertLessThan(name.count, 120)
        fixture.update(nil, after: 60)
        XCTAssertEqual(try fixture.records().first?.name, name)
        await fixture.store.deactivate()
    }

    func testReadingTimeFailedStopRetainsOwnershipAndRetriesTheOriginalInterval() async throws {
        let fixture = try makeReadingTimeFixture(failingSaveAttempts: [2])
        fixture.update("Chapter")
        let sessionID = fixture.store.active?.clientSessionID

        fixture.update(nil, after: 60)

        XCTAssertEqual(fixture.store.active?.clientSessionID, sessionID)
        XCTAssertEqual(fixture.store.storageWriteErrorMessage, "Forced save failure")
        XCTAssertNil(try fixture.records().first?.endedAt)

        fixture.update(nil, after: 90)

        XCTAssertNil(fixture.store.active)
        XCTAssertNil(fixture.store.storageWriteErrorMessage)
        XCTAssertEqual(try fixture.records().count, 1)
        XCTAssertEqual(try fixture.records().first?.durationMs, 90_000)
        await fixture.store.deactivate()
    }

    func testReadingTimeFailedReplacementDoesNotClaimTheOtherReadersInterval() async throws {
        let fixture = try makeReadingTimeFixture(failingSaveAttempts: [2])
        fixture.update("Chapter")
        let firstID = fixture.store.active?.clientSessionID
        let nextReader = ReadingTimeTracker()

        nextReader.update(title: "Chapter", store: fixture.store, at: fixture.startedAt.addingTimeInterval(60))
        nextReader.update(title: nil, store: fixture.store, at: fixture.startedAt.addingTimeInterval(70))

        XCTAssertEqual(fixture.store.active?.clientSessionID, firstID)
        XCTAssertNil(try fixture.records().first?.endedAt)
        fixture.update(nil, after: 90)
        XCTAssertEqual(try fixture.records().first?.durationMs, 90_000)
        await fixture.store.deactivate()
    }
}

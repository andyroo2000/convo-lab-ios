import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testJournalTimePausesAndDoesNotStopAnotherActivity() async throws {
        let fixture = try makeReadingTimeFixture()
        let tracker = ReadingTimeTracker(activity: .journal)
        let start = fixture.startedAt
        tracker.update(title: "Journal", store: fixture.store, at: start)
        tracker.update(title: nil, store: fixture.store, at: start.addingTimeInterval(60))
        let record = try XCTUnwrap(fixture.records().first)
        XCTAssertEqual(record.activity, "journal")
        XCTAssertEqual(record.category, "writing")
        XCTAssertEqual(record.durationMs, 60_000)
        tracker.update(title: "Journal", store: fixture.store, at: start.addingTimeInterval(120))
        fixture.store.start(activity: .conversation, source: .manual, at: start.addingTimeInterval(180))
        let manualID = fixture.store.active?.clientSessionID
        tracker.update(title: nil, store: fixture.store, at: start.addingTimeInterval(240))
        XCTAssertEqual(fixture.store.active?.clientSessionID, manualID)
        XCTAssertEqual(try fixture.records().filter { $0.activity == "journal" }.map(\.durationMs), [60_000, 60_000])
        await fixture.store.deactivate()
    }
    func testJournalEntryCanAppearBeforeListDisappears() async throws {
        let fixture = try makeReadingTimeFixture()
        let list = ReadingTimeTracker(activity: .journal)
        let entry = ReadingTimeTracker(activity: .journal)
        list.update(title: "Journal", store: fixture.store, at: fixture.startedAt)
        entry.update(title: "Journal", store: fixture.store, at: fixture.startedAt.addingTimeInterval(30))
        let entryID = fixture.store.active?.clientSessionID
        list.update(title: nil, store: fixture.store, at: fixture.startedAt.addingTimeInterval(31))
        XCTAssertEqual(fixture.store.active?.clientSessionID, entryID)
        entry.update(title: nil, store: fixture.store, at: fixture.startedAt.addingTimeInterval(90))
        XCTAssertEqual(try fixture.records().map(\.durationMs), [30_000, 60_000])
        await fixture.store.deactivate()
    }

}

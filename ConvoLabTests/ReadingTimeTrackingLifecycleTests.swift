import Foundation
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testReadingTimeRecordsPassiveReadingBeyondFiveMinutesAndRetriesOfflineUpload() async throws {
        let fixture = try makeReadingTimeFixture()
        fixture.update("ライオンと子犬")
        let sessionID = try XCTUnwrap(fixture.store.active?.clientSessionID)
        fixture.update(nil, after: 720)
        await fixture.store.synchronize()

        let record = try XCTUnwrap(fixture.records().first)
        XCTAssertEqual(record.durationMs, 720_000)
        XCTAssertEqual(record.activity, "reading")
        XCTAssertEqual(record.source, "automatic")
        XCTAssertEqual(record.category, "immerse")
        XCTAssertEqual(record.origin, "ios")
        XCTAssertTrue(record.syncPending)

        let uploads = LockedCounter()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/study/activity-sessions/batch" {
                let sessions = try Self.batchSessions(from: request)
                let posted = try XCTUnwrap(sessions.first)
                XCTAssertEqual(posted["clientSessionId"] as? String, sessionID)
                XCTAssertEqual(posted["name"] as? String, "ライオンと子犬")
                XCTAssertEqual(posted["durationMs"] as? Int, 720_000)
                XCTAssertEqual(posted["activity"] as? String, "reading")
                XCTAssertEqual(posted["source"] as? String, "automatic")
                XCTAssertNil(posted["category"], "The server derives category from activity.")
                XCTAssertEqual(posted["origin"] as? String, "ios")
                XCTAssertNil(posted["audioPlaybackMs"])
                _ = uploads.next()
                let acknowledged = sessions.map { session in
                    var result = session
                    result["category"] = "immerse"
                    return result
                }
                return try Self.jsonResponse(for: request, body: acknowledged)
            }
            if request.url?.path == "/api/study/activity-analytics" {
                return try analyticsResponse(for: request)
            }
            return try Self.jsonResponse(for: request, body: [])
        }
        await fixture.store.synchronize()

        XCTAssertGreaterThan(uploads.current, 0)
        XCTAssertFalse(record.syncPending)
        XCTAssertEqual(try fixture.records().count, 1)
        await fixture.store.deactivate()
    }

    func testReadingTimePauseAndResumeExcludeTimeOutsideReader() async throws {
        let fixture = try makeReadingTimeFixture()
        fixture.update("Chapter")
        fixture.update(nil, after: 90)
        fixture.update("Chapter", after: 600)
        fixture.update(nil, after: 720)

        let records = try fixture.records()
        XCTAssertEqual(records.map(\.durationMs), [90_000, 120_000])
        XCTAssertEqual(records[0].endedAt, fixture.startedAt.addingTimeInterval(90))
        XCTAssertEqual(records[1].startedAt, fixture.startedAt.addingTimeInterval(600))
        XCTAssertNotEqual(records[0].clientSessionID, records[1].clientSessionID)
        await fixture.store.deactivate()
    }

    func testReadingTimeRepeatedPageUpdatesPreserveTheOriginalInterval() async throws {
        let fixture = try makeReadingTimeFixture()
        fixture.update("Chapter")
        let original = fixture.store.active

        fixture.update("Chapter", after: 60)
        fixture.update("Chapter", after: 400)

        XCTAssertEqual(fixture.store.active, original)
        XCTAssertEqual(try fixture.records().count, 1)
        fixture.update(nil, after: 900)
        XCTAssertEqual(try fixture.records().first?.durationMs, 900_000)
        await fixture.store.deactivate()
    }

    func testReadingTimeDoesNotCreateAnIntervalWithoutLoadedContentOrAnAccount() async throws {
        let fixture = try makeReadingTimeFixture()
        fixture.update(nil)
        XCTAssertNil(fixture.store.active)
        XCTAssertTrue(try fixture.records().isEmpty)

        await fixture.store.deactivate()
        fixture.update("Late document response", after: 30)

        XCTAssertNil(fixture.store.active)
        XCTAssertTrue(try fixture.records().isEmpty)
    }

    func testReadingTimeRestartsAfterAppLifecycleBackstopClosedTheInterval() async throws {
        let fixture = try makeReadingTimeFixture()
        fixture.update("Chapter")
        fixture.store.stopForegroundAutomaticTracking(at: fixture.startedAt.addingTimeInterval(60))

        fixture.update("Chapter", after: 600)
        fixture.update(nil, after: 660)

        XCTAssertEqual(try fixture.records().map(\.durationMs), [60_000, 60_000])
        await fixture.store.deactivate()
    }
}

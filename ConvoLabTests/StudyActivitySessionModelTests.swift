import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testAnalyticsRangesMapToExistingDrillDownViews() {
        XCTAssertEqual(StudyTimeRange.today.title, "Day")
        XCTAssertEqual(StudyTimeRange.year.drillDownTarget, .month)
        XCTAssertEqual(StudyTimeRange.month.drillDownTarget, .today)
        XCTAssertEqual(StudyTimeRange.week.drillDownTarget, .today)
        XCTAssertNil(StudyTimeRange.today.drillDownTarget)
        XCTAssertNil(StudyTimeRange.all.drillDownTarget)
    }

    func testStudyTimeSwipeRecognizerOnlyAcceptsHorizontalMovement() {
        XCTAssertTrue(StudyTimeSwipeRecognition.isHorizontal(translation: CGPoint(x: 40, y: 5)))
        XCTAssertTrue(StudyTimeSwipeRecognition.isHorizontal(translation: CGPoint(x: -40, y: 5)))
        XCTAssertFalse(StudyTimeSwipeRecognition.isHorizontal(translation: CGPoint(x: 5, y: 40)))
        XCTAssertFalse(StudyTimeSwipeRecognition.isHorizontal(translation: CGPoint(x: 5, y: -40)))
        XCTAssertFalse(StudyTimeSwipeRecognition.isHorizontal(translation: CGPoint(x: 20, y: 20)))
    }

    func testStudyTimeSwipeNavigationRequiresHorizontalThresholdAndAvailablePeriod() {
        XCTAssertEqual(
            StudyTimeSwipeRecognition.navigation(
                translation: CGPoint(x: 20, y: 2),
                projectedTranslationX: 80,
                canNavigateLater: false
            ),
            .previous
        )
        XCTAssertEqual(
            StudyTimeSwipeRecognition.navigation(
                translation: CGPoint(x: -80, y: 2),
                projectedTranslationX: -100,
                canNavigateLater: true
            ),
            .next
        )
        XCTAssertEqual(
            StudyTimeSwipeRecognition.navigation(
                translation: CGPoint(x: -80, y: 2),
                projectedTranslationX: -100,
                canNavigateLater: false
            ),
            .snapBack
        )
        XCTAssertEqual(
            StudyTimeSwipeRecognition.navigation(
                translation: CGPoint(x: 80, y: 100),
                projectedTranslationX: 120,
                canNavigateLater: true
            ),
            .snapBack
        )
        XCTAssertEqual(
            StudyTimeSwipeRecognition.navigation(
                translation: CGPoint(x: 60, y: 2),
                projectedTranslationX: 60,
                canNavigateLater: true
            ),
            .snapBack
        )
    }

    func testActivitiesMapToOnePrimaryCategory() {
        XCTAssertEqual(StudyActivityKind.cardReview.offlineFallbackCategory, .review)
        XCTAssertEqual(StudyActivityKind.dailyAudio.offlineFallbackCategory, .listen)
        XCTAssertEqual(StudyActivityKind.cardCreation.offlineFallbackCategory, .create)
        XCTAssertEqual(StudyActivityKind.tv.offlineFallbackCategory, .immerse)
        XCTAssertEqual(StudyActivityKind.podcast.offlineFallbackCategory, .immerse)
        XCTAssertEqual(StudyActivityKind.reading.offlineFallbackCategory, .immerse)
        XCTAssertEqual(StudyActivityKind.conversation.offlineFallbackCategory, .conversation)
        XCTAssertEqual(StudyActivityKind.wanikaniReview.offlineFallbackCategory, .wanikani)
        XCTAssertEqual(StudyActivityKind.other.offlineFallbackCategory, .immerse)
    }

    func testPersistedCategoryRetainsLastKnownAuthorityClassification() throws {
        let conversation = StudyActivitySession(
            id: nil,
            clientSessionId: "018f22d2-6d38-7000-8000-000000000002",
            category: .conversation,
            activity: .conversation,
            source: .manual,
            name: "Lesson",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            durationMs: 3_600_000,
            audioPlaybackMs: nil,
            cardsCreated: nil
        )
        let record = LocalStudyActivitySession(session: conversation, userID: 42)
        record.category = StudyActivityCategory.immerse.rawValue

        XCTAssertEqual(try XCTUnwrap(record.session).category, .immerse)
    }

    func testBatchEncodesRetrySafeClientIdentityAndOutputMetrics() throws {
        let session = StudyActivitySession(
            id: "server-session-1",
            clientSessionId: "018f22d2-6d38-7000-8000-000000000001",
            category: .create,
            activity: .cardCreation,
            source: .manual,
            name: "Episode cards",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            durationMs: 3_600_000,
            audioPlaybackMs: nil,
            cardsCreated: 12
        )

        let data = try JSONEncoder().encode(StudyActivityBatchRequest(sessions: [session]))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try XCTUnwrap((body["sessions"] as? [[String: Any]])?.first)

        XCTAssertEqual(
            encoded["clientSessionId"] as? String,
            "018f22d2-6d38-7000-8000-000000000001"
        )
        XCTAssertEqual(encoded["id"] as? String, "server-session-1")
        XCTAssertNil(encoded["category"])
        XCTAssertEqual(encoded["activity"] as? String, "card_creation")
        XCTAssertEqual(encoded["origin"] as? String, "ios")
        XCTAssertEqual(encoded["cardsCreated"] as? Int, 12)

        let legacyData = try JSONEncoder().encode(
            StudyActivityBatchRequest(
                sessions: [makeSession(source: .manual, origin: .legacy)]
            )
        )
        let legacyBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        )
        let legacySession = try XCTUnwrap(
            (legacyBody["sessions"] as? [[String: Any]])?.first
        )
        XCTAssertNil(legacySession["origin"])
    }

    func testSessionOriginDecodingIsBackwardAndForwardCompatible() throws {
        for (originValue, expected) in [
            (nil, StudyActivityOrigin.legacy),
            (NSNull(), .legacy),
            ("future_provider", .legacy),
            ("google_calendar", .googleCalendar),
        ] as [(Any?, StudyActivityOrigin)] {
            var object = studyActivitySessionJSONObject()
            if let originValue {
                object["origin"] = originValue
            }
            let data = try JSONSerialization.data(withJSONObject: object)

            let session = try studyActivityDecoder().decode(
                StudyActivitySession.self,
                from: data
            )

            XCTAssertEqual(session.origin, expected)
        }

        var futureObject = studyActivitySessionJSONObject()
        futureObject["origin"] = "future_provider"
        let future = try studyActivityDecoder().decode(
            StudyActivitySession.self,
            from: JSONSerialization.data(withJSONObject: futureObject)
        )
        XCTAssertEqual(future.origin, .legacy)
        XCTAssertTrue(future.hasUnknownOrigin)
        XCTAssertFalse(future.isEditable)

        let persisted = LocalStudyActivitySession(session: future, userID: 42)
        XCTAssertEqual(persisted.origin, "future_provider")
        let roundTripped = try XCTUnwrap(persisted.session)
        XCTAssertEqual(roundTripped.origin, .legacy)
        XCTAssertTrue(roundTripped.hasUnknownOrigin)
        XCTAssertFalse(roundTripped.isEditable)
    }

    func testProviderProvenanceIsSeparateFromCaptureSourceAndConservativelyEditable() {
        XCTAssertEqual(
            makeSession(source: .manual, origin: .googleCalendar).provider,
            .googleCalendar
        )
        XCTAssertEqual(makeSession(source: .calendar, origin: .ios).source, .calendar)
        XCTAssertNil(makeSession(source: .manual, origin: .web).provider)

        for origin in [StudyActivityOrigin.legacy, .ios, .web] {
            XCTAssertTrue(makeSession(source: .manual, origin: origin).isEditable)
        }
        XCTAssertTrue(makeSession(source: .calendar, origin: .ios).isEditable)
        XCTAssertFalse(makeSession(source: .automatic, origin: .ios).isEditable)
        XCTAssertFalse(makeSession(source: .manual, origin: .googleCalendar).isEditable)
        XCTAssertFalse(makeSession(source: .manual, origin: .waniKani).isEditable)
        XCTAssertFalse(makeSession(source: .manual, origin: .system).isEditable)
    }

    func testEditableEntriesCopyAndFilterMatchTheUIContract() {
        XCTAssertEqual(StudyTimeEditableEntries.sectionTitle, "Editable entries")
        XCTAssertEqual(
            StudyTimeEditableEntries.emptyDescription,
            "Timers and manually added study time you can edit appear here."
        )

        let editable = makeSession(source: .manual, origin: .ios)
        let automatic = makeSession(source: .automatic, origin: .ios)
        let provider = makeSession(source: .manual, origin: .googleCalendar)

        XCTAssertEqual(
            StudyTimeEditableEntries.filter([provider, automatic, editable]),
            [editable]
        )
    }

    func testOriginsSurviveLocalPersistenceWithSafeLegacyFallback() throws {
        for origin in [
            StudyActivityOrigin.legacy,
            .ios,
            .web,
            .googleCalendar,
            .waniKani,
            .system,
        ] {
            let record = LocalStudyActivitySession(
                session: makeSession(source: .manual, origin: origin),
                userID: 42
            )
            XCTAssertEqual(try XCTUnwrap(record.session).origin, origin)
        }

        let unknown = LocalStudyActivitySession(
            session: makeSession(source: .manual, origin: .web),
            userID: 42
        )
        unknown.origin = "future_provider"
        let unknownSession = try XCTUnwrap(unknown.session)
        XCTAssertEqual(unknownSession.origin, .legacy)
        XCTAssertTrue(unknownSession.hasUnknownOrigin)
        XCTAssertFalse(unknownSession.isEditable)

        let active = StudyTimeStore.ActiveSession(
            clientSessionID: "018f22d2-6d38-7000-8000-000000000097",
            category: .immerse,
            activity: .reading,
            source: .manual,
            name: nil,
            startedAt: Date(timeIntervalSince1970: 1_753_732_800),
            cardsCreated: 0
        )
        let local = LocalStudyActivitySession(active: active, userID: 42)
        local.endedAt = active.startedAt.addingTimeInterval(600)
        local.durationMs = 600_000
        XCTAssertEqual(try XCTUnwrap(local.session).origin, .ios)
    }

}

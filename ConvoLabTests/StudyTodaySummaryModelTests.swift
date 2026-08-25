import Foundation
import Testing
@testable import ConvoLab

@MainActor
struct StudyTodaySummaryModelTests {
    @Test func decodesWaniKaniReviewSummaryAndLegacySnapshot() throws {
        let current = try StorageCodec.decoder.decode(
            KnownKanjiSnapshot.self,
            from: Data(
                #"{"version":4,"kanji":["日"],"manualKanji":[],"wanikani":{"connected":true,"lastSyncedAt":"2026-08-24T18:00:00Z","reviewCount":32,"reviewCountUpdatedAt":"2026-08-24T18:00:00Z"}}"#.utf8
            )
        )
        let legacy = try StorageCodec.decoder.decode(
            KnownKanjiSnapshot.self,
            from: Data(
                #"{"version":3,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
            )
        )

        #expect(current.wanikani.reviewCount == 32)
        #expect(current.wanikani.reviewCountUpdatedAt != nil)
        #expect(legacy.wanikani.reviewCount == nil)
        #expect(legacy.wanikani.reviewCountUpdatedAt == nil)
    }

    @Test func decodesNextLessonAndLegacyCalendarStatus() throws {
        let current = try StorageCodec.decoder.decode(
            GoogleCalendarConnectionStatus.self,
            from: Data(
                #"{"connected":true,"accountEmail":"learner@example.com","scopes":[],"settings":null,"connectedAt":null,"lastSyncedAt":null,"sync":null,"nextLesson":{"title":"iTalki","startsAt":"2026-08-24T23:00:00Z","endsAt":"2026-08-25T00:00:00Z"}}"#.utf8
            )
        )
        let legacy = try StorageCodec.decoder.decode(
            GoogleCalendarConnectionStatus.self,
            from: Data(
                #"{"connected":false,"accountEmail":null,"scopes":[],"settings":null,"connectedAt":null,"lastSyncedAt":null,"sync":null}"#.utf8
            )
        )

        #expect(current.nextLesson?.title == "iTalki")
        #expect(legacy.nextLesson == nil)
    }
}

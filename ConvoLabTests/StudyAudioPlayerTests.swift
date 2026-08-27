import XCTest
@testable import ConvoLab

@MainActor
final class StudyAudioPlayerTests: XCTestCase {
    func testLongFormPlaybackBlocksStudyClip() {
        XCTAssertFalse(
            StudyAudioPlayer.allowsPlayback(
                whileLongFormAudioIsPlaying: true
            )
        )
        XCTAssertTrue(
            StudyAudioPlayer.allowsPlayback(
                whileLongFormAudioIsPlaying: false
            )
        )
    }

    func testReplacingAPlayingTrackRequiresANewPlaybackEvent() {
        let oldTrack = makeDailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 1))
        let regeneratedTrack = makeDailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(
            AudioPlayer.replacesPlayingTrack(
                isPlaying: true,
                currentTrackIdentity: DailyAudioPlaybackIdentity(track: oldTrack),
                newTrackIdentity: DailyAudioPlaybackIdentity(track: regeneratedTrack)
            )
        )
        XCTAssertFalse(
            AudioPlayer.replacesPlayingTrack(
                isPlaying: true,
                currentTrackIdentity: DailyAudioPlaybackIdentity(track: oldTrack),
                newTrackIdentity: DailyAudioPlaybackIdentity(track: oldTrack)
            )
        )
        XCTAssertFalse(
            AudioPlayer.replacesPlayingTrack(
                isPlaying: false,
                currentTrackIdentity: DailyAudioPlaybackIdentity(track: oldTrack),
                newTrackIdentity: DailyAudioPlaybackIdentity(track: regeneratedTrack)
            )
        )
    }

    func testRegeneratedTrackWithSameIDStartsFromBeginning() {
        let oldTrack = makeDailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 1))
        let regeneratedTrack = makeDailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2))
        let oldIdentity = DailyAudioPlaybackIdentity(track: oldTrack)
        let regeneratedIdentity = DailyAudioPlaybackIdentity(track: regeneratedTrack)

        XCTAssertNotEqual(oldIdentity, regeneratedIdentity)
        XCTAssertNotEqual(
            AudioPlayer.positionKey(oldIdentity),
            AudioPlayer.positionKey(regeneratedIdentity)
        )
        XCTAssertTrue(
            AudioPlayer.replacesPlayingTrack(
                isPlaying: true,
                currentTrackIdentity: oldIdentity,
                newTrackIdentity: regeneratedIdentity
            )
        )
    }

    func testStartingARevisionPrunesOnlySupersededResumePositions() {
        let currentTrack = makeDailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2))
        let oldKey = "daily-audio.position.track-a.1000"
        let currentKey = "daily-audio.position.track-a.2000"
        let legacyKey = "daily-audio.position.track-a"
        let unrelatedKey = "daily-audio.position.track-b.1000"

        XCTAssertEqual(
            Set(AudioPlayer.stalePositionKeys(
                in: [oldKey, currentKey, legacyKey, unrelatedKey],
                for: DailyAudioPlaybackIdentity(track: currentTrack)
            )),
            Set([oldKey, legacyKey])
        )
    }

    func testActivePlaybackStopsWhenTheStorePublishesANewerRevision() {
        let oldTrack = makeDailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 1))
        let regeneratedTrack = makeDailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2))

        XCTAssertFalse(
            AudioPlayer.currentTrackWasSuperseded(
                DailyAudioPlaybackIdentity(track: oldTrack),
                by: [oldTrack]
            )
        )
        XCTAssertTrue(
            AudioPlayer.currentTrackWasSuperseded(
                DailyAudioPlaybackIdentity(track: oldTrack),
                by: [regeneratedTrack]
            )
        )
    }

    func testLongFormPlayerRepeatCanBeToggled() {
        XCTAssertTrue(AudioPlayer.toggledRepeatState(false))
        XCTAssertFalse(AudioPlayer.toggledRepeatState(true))
    }

    func testOnlyTerminalPlaybackRecordsAnEpisodeCompletion() {
        XCTAssertTrue(AudioPlayer.shouldRecordCompletion(isRepeating: false))
        XCTAssertFalse(AudioPlayer.shouldRecordCompletion(isRepeating: true))
    }

    private func makeDailyAudioTrack(updatedAt: Date) -> DailyAudioTrack {
        DailyAudioTrack(
            id: "track-a",
            practiceId: "practice-a",
            mode: "recognition",
            status: "ready",
            title: "Track A",
            sortOrder: 0,
            audioUrl: "https://example.com/audio.m4a",
            approxDurationSeconds: 60,
            updatedAt: updatedAt
        )
    }
}

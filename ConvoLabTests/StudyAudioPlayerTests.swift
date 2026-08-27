import XCTest
@testable import ConvoLab

@MainActor
final class StudyAudioPlayerTests: XCTestCase {
    private final class CompletionRecorder {
        var titles: [String] = []
    }

    // Xcode 26.2's simulator runtime can double-free task-local state while
    // destroying an exercised @Observable object with an isolated deinit.
    private static var playersRetainedForSimulatorLifetime: [AudioPlayer] = []

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

    func testActualCompletionPathRecordsTerminalPlaybackButNotRepeatLoops() {
        let player = AudioPlayer(deterministicUITestBackend: ())
        let track = makeDailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 1))
        let url = URL(string: "https://example.com/audio.m4a")!
        let recorder = CompletionRecorder()
        player.setPlaybackCompletionHandler { recorder.titles.append($0) }

        player.play(url: url, track: track)
        player.simulatePlaybackCompletionForTesting()

        XCTAssertEqual(recorder.titles, ["Track A"])
        XCTAssertFalse(player.isPlaying)

        player.play(url: url, track: track)
        player.toggleRepeat()
        player.simulatePlaybackCompletionForTesting()

        XCTAssertEqual(recorder.titles, ["Track A"])
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.elapsed, 0)
        player.setPlaybackCompletionHandler { _ in }
        Self.playersRetainedForSimulatorLifetime.append(player)
    }

    func testCompletionMarkerPinsStudyTimeFieldsAndNameLimit() {
        let startedAt = Date(timeIntervalSince1970: 1_234)
        let marker = DailyAudioCompletionMarker(
            title: String(repeating: "A", count: 150),
            startedAt: startedAt
        )

        XCTAssertEqual(marker.activity, .dailyAudio)
        XCTAssertEqual(marker.source, .automatic)
        XCTAssertEqual(marker.startedAt, startedAt)
        XCTAssertEqual(marker.duration, 0)
        XCTAssertEqual(marker.name.count, DailyAudioCompletionMarker.maximumNameLength)
        XCTAssertTrue(marker.name.hasPrefix(DailyAudioCompletionMarker.namePrefix))
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

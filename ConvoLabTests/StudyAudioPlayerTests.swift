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
        let player = AudioPlayer(deterministicUITestBackend: ())
        let oldTrack = makeDailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 1))
        let regeneratedTrack = makeDailyAudioTrack(updatedAt: Date(timeIntervalSince1970: 2))
        let url = URL(fileURLWithPath: "/tmp/daily-audio-test.m4a")

        player.play(url: url, track: oldTrack)
        player.seek(to: 25)
        XCTAssertEqual(player.elapsed, 25)

        player.play(url: url, track: regeneratedTrack)

        XCTAssertEqual(player.elapsed, 0)
        XCTAssertFalse(player.isCurrent(oldTrack))
        XCTAssertTrue(player.isCurrent(regeneratedTrack))
    }

    func testLongFormPlayerRepeatCanBeToggled() {
        XCTAssertTrue(AudioPlayer.toggledRepeatState(false))
        XCTAssertFalse(AudioPlayer.toggledRepeatState(true))
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

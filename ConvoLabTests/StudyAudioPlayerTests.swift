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
        XCTAssertTrue(
            AudioPlayer.replacesPlayingTrack(
                isPlaying: true,
                currentTrackID: "track-a",
                newTrackID: "track-b"
            )
        )
        XCTAssertFalse(
            AudioPlayer.replacesPlayingTrack(
                isPlaying: true,
                currentTrackID: "track-a",
                newTrackID: "track-a"
            )
        )
        XCTAssertFalse(
            AudioPlayer.replacesPlayingTrack(
                isPlaying: false,
                currentTrackID: "track-a",
                newTrackID: "track-b"
            )
        )
    }

    func testLongFormPlayerRepeatCanBeToggled() {
        XCTAssertTrue(AudioPlayer.toggledRepeatState(false))
        XCTAssertFalse(AudioPlayer.toggledRepeatState(true))
    }
}

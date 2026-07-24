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
}

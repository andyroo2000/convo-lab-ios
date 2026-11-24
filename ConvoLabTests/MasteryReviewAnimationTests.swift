import CoreGraphics
import XCTest
@testable import ConvoLab

final class MasteryReviewAnimationTests: XCTestCase {
    @MainActor
    func testMasteryChangesUseLevelOrderAndOnlyPromotionsRise() {
        typealias Change = MasteryReviewAnimation.Change
        for level in StudyMasteryLevel.allCases {
            XCTAssertNil(Change(from: level, to: level))
        }
        let up = Change(from: .apprentice, to: .burned)
        let down = Change(from: .master, to: .guru)
        XCTAssertEqual(up, .promotion)
        XCTAssertEqual(down, .demotion)
        XCTAssertEqual(up?.exitOffset(reduceMotion: false), -28)
        XCTAssertEqual(up?.exitOffset(reduceMotion: true), 0)
        XCTAssertEqual(down?.exitOffset(reduceMotion: false), 0)
    }

    @MainActor
    func testPromptAutoplayWaitsForMasteryAnimationToFinish() {
        let cardID = "next-card"

        XCTAssertFalse(
            StudySessionView.shouldAutoplayPromptAudio(
                cardID: cardID,
                currentCardID: cardID,
                cardAllowsAutoplay: true,
                hasMasteryAnimation: true
            )
        )
        XCTAssertTrue(
            StudySessionView.shouldAutoplayPromptAudio(
                cardID: cardID,
                currentCardID: cardID,
                cardAllowsAutoplay: true,
                hasMasteryAnimation: false
            )
        )
    }

}

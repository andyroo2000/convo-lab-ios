import CoreGraphics
import XCTest
@testable import ConvoLab

final class MasteryReviewAnimationTests: XCTestCase {
    @MainActor
    func testRailStaysNearTheTopOfTheCardOverlay() {
        let availableHeight = CGFloat(600)
        let railTop = MasteryReviewAnimation.railCenterY(
            availableHeight: availableHeight
        ) - MasteryReviewAnimation.railHeight / 2

        XCTAssertGreaterThanOrEqual(railTop, 12)
        XCTAssertLessThan(railTop, availableHeight / 2)
    }

    @MainActor
    func testSegmentWidthKeepsEnlightenedReadableOnPhone() {
        XCTAssertGreaterThanOrEqual(
            MasteryReviewAnimation.segmentWidth(for: 320),
            150
        )
    }

    @MainActor
    func testEveryMasteryLevelHasAColor() {
        for level in StudyMasteryLevel.allCases {
            _ = MasteryReviewAnimation.color(for: level)
        }
    }

    @MainActor
    func testAnnouncementsDistinguishProgressAndFailure() {
        XCTAssertEqual(
            MasteryReviewAnimation.announcement(
                label: "復習",
                fromIndex: StudyMasteryLevel.master.rank,
                toIndex: StudyMasteryLevel.enlightened.rank,
                passed: true
            ),
            "復習 advanced to Enlightened."
        )
        XCTAssertEqual(
            MasteryReviewAnimation.announcement(
                label: "復習",
                fromIndex: StudyMasteryLevel.master.rank,
                toIndex: StudyMasteryLevel.guru.rank,
                passed: true
            ),
            "復習 is now Guru."
        )
        XCTAssertEqual(
            MasteryReviewAnimation.announcement(
                label: "復習",
                fromIndex: StudyMasteryLevel.master.rank,
                toIndex: StudyMasteryLevel.master.rank,
                passed: false
            ),
            "復習 remains Master. Try again."
        )
        XCTAssertEqual(
            MasteryReviewAnimation.announcement(
                label: "復習",
                fromIndex: StudyMasteryLevel.master.rank,
                toIndex: StudyMasteryLevel.apprentice.rank,
                passed: false
            ),
            "復習 dropped to Apprentice."
        )
    }

    @MainActor
    func testReducedMotionKeepsAStaticPassOrFailSignal() {
        XCTAssertEqual(
            MasteryReviewAnimation.reducedMotionStatus(passed: true),
            "Passed"
        )
        XCTAssertEqual(
            MasteryReviewAnimation.reducedMotionStatus(passed: false),
            "Try again"
        )
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

import CoreGraphics
import XCTest
@testable import ConvoLab

final class MasteryReviewAnimationTests: XCTestCase {
    @MainActor
    func testRailClearsDynamicIslandSafeArea() {
        let safeAreaTop = CGFloat(62)
        let railTop = MasteryReviewAnimation.railCenterY(
            safeAreaTop: safeAreaTop
        ) - MasteryReviewAnimation.railHeight / 2

        XCTAssertGreaterThanOrEqual(railTop, safeAreaTop + 12)
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

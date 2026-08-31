import CoreGraphics
import XCTest
@testable import ConvoLab

final class MasteryReviewAnimationTests: XCTestCase {
    @MainActor
    func testRailAndScaledNodesFitInsideCompactFeedbackLane() {
        let railTop = MasteryReviewAnimation.railCenterY
            - MasteryReviewAnimation.railHeight / 2
        let railBottom = MasteryReviewAnimation.railCenterY
            + MasteryReviewAnimation.railHeight / 2
        let scaledNodeBottom = MasteryReviewAnimation.nodeTop
            + 9
            + (9 * 1.28)
        let scaledFailureHaloBottom = MasteryReviewAnimation.failureHaloTop
            + 15
            + (15 * 1.65)

        XCTAssertGreaterThanOrEqual(railTop, 0)
        XCTAssertLessThanOrEqual(
            railBottom,
            MasteryReviewAnimation.feedbackLaneHeight
        )
        XCTAssertLessThan(
            scaledNodeBottom,
            MasteryReviewAnimation.railHeight
        )
        XCTAssertLessThan(
            scaledFailureHaloBottom,
            MasteryReviewAnimation.railHeight
        )
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
    func testAnimationAddsOneSecondOfSettledHoldTime() {
        XCTAssertEqual(MasteryReviewAnimation.addedHoldMilliseconds, 1_000)
        XCTAssertEqual(MasteryReviewAnimation.settledHoldMilliseconds, 1_320)
        XCTAssertEqual(MasteryReviewAnimation.reducedMotionHoldMilliseconds, 1_450)
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

    @MainActor
    func testWrapUpWaitsForAuthoritativeCompletionBeforeDismissal() {
        XCTAssertFalse(
            StudySessionView.canDismissWrapUp(isCompletionRefreshPending: true)
        )
        XCTAssertTrue(
            StudySessionView.canDismissWrapUp(isCompletionRefreshPending: false)
        )
    }

    @MainActor
    func testMatchingDeferredCompletionDoesNotRewindAwardPresentation() {
        let sessionID = UUID()
        let current = StudyAchievementCompletion(
            id: sessionID,
            records: [],
            newAwardIDs: ["reviews.first", "reviews.second"],
            celebrationPresented: false
        )
        let matchingRefresh = StudyAchievementCompletion(
            id: sessionID,
            records: [],
            newAwardIDs: current.newAwardIDs,
            celebrationPresented: true
        )
        let newlyEarnedRefresh = StudyAchievementCompletion(
            id: sessionID,
            records: [],
            newAwardIDs: current.newAwardIDs + ["reviews.third"],
            celebrationPresented: false
        )

        XCTAssertFalse(StudySessionView.shouldResetCompletionPresentation(
            current: current,
            updated: matchingRefresh
        ))
        XCTAssertFalse(StudySessionView.shouldResetCompletionPresentation(
            current: current,
            updated: newlyEarnedRefresh
        ))

        let midCarousel = StudySessionView.reconciledCompletionPresentation(
            current: current,
            updated: newlyEarnedRefresh,
            currentAwardIDs: current.newAwardIDs,
            currentAwardIndex: 1,
            celebrationPresented: false
        )
        XCTAssertEqual(midCarousel.awardIDs, [
            "reviews.first",
            "reviews.second",
            "reviews.third",
        ])
        XCTAssertEqual(midCarousel.currentAwardIndex, 1)
        XCTAssertFalse(midCarousel.celebrationPresented)

        let finishedCarousel = StudySessionView.reconciledCompletionPresentation(
            current: StudyAchievementCompletion(
                id: sessionID,
                records: [],
                newAwardIDs: ["reviews.first"],
                celebrationPresented: true
            ),
            updated: StudyAchievementCompletion(
                id: sessionID,
                records: [],
                newAwardIDs: ["reviews.first", "reviews.third"],
                celebrationPresented: false
            ),
            currentAwardIDs: ["reviews.first"],
            currentAwardIndex: 0,
            celebrationPresented: true
        )
        XCTAssertEqual(finishedCarousel.awardIDs, ["reviews.first", "reviews.third"])
        XCTAssertEqual(finishedCarousel.currentAwardIndex, 1)
        XCTAssertFalse(finishedCarousel.celebrationPresented)
    }
}

import CoreGraphics
import XCTest
@testable import ConvoLab

final class MasteryPromotionAnimationTests: XCTestCase {
    @MainActor
    func testCloudClearsDynamicIslandSafeArea() {
        let safeAreaTop = CGFloat(62)
        let cloudTop = MasteryPromotionAnimation.cloudCenterY(
            safeAreaTop: safeAreaTop
        ) - MasteryPromotionAnimation.cloudSize.height / 2

        XCTAssertGreaterThanOrEqual(cloudTop, safeAreaTop + 8)
    }

    @MainActor
    func testEnlightenedCloudProvidesRoomForLongLevelName() {
        XCTAssertGreaterThanOrEqual(MasteryPromotionAnimation.cloudSize.width, 210)
    }

    @MainActor
    func testPromptAutoplayWaitsForMasteryPromotionToFinish() {
        let cardID = "next-card"

        XCTAssertFalse(
            StudySessionView.shouldAutoplayPromptAudio(
                cardID: cardID,
                currentCardID: cardID,
                cardAllowsAutoplay: true,
                hasMasteryPromotion: true
            )
        )
        XCTAssertTrue(
            StudySessionView.shouldAutoplayPromptAudio(
                cardID: cardID,
                currentCardID: cardID,
                cardAllowsAutoplay: true,
                hasMasteryPromotion: false
            )
        )
    }
}

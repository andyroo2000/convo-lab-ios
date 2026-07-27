import CoreGraphics
import XCTest
@testable import ConvoLab

final class MasteryPromotionAnimationTests: XCTestCase {
    @MainActor
    func testCloudClearsDynamicIslandSafeArea() {
        let safeAreaTop = CGFloat(62)
        let cloudTop = MasteryPromotionAnimation.cloudCenterY(
            safeAreaTop: safeAreaTop
        ) - 48

        XCTAssertGreaterThanOrEqual(cloudTop, safeAreaTop + 8)
    }
}

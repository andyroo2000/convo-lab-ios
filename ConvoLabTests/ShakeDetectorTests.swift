import UIKit
import XCTest
@testable import ConvoLab

final class ShakeDetectorTests: XCTestCase {
    @MainActor
    func testMotionShakeInvokesHandler() {
        var shakeCount = 0
        let controller = ShakeViewController {
            shakeCount += 1
        }

        controller.motionEnded(.motionShake, with: nil)

        XCTAssertEqual(shakeCount, 1)
    }

    @MainActor
    func testNonShakeMotionDoesNotInvokeHandler() {
        var shakeCount = 0
        let controller = ShakeViewController {
            shakeCount += 1
        }

        controller.motionEnded(.remoteControlPlay, with: nil)

        XCTAssertEqual(shakeCount, 0)
    }

    @MainActor
    func testDisabledDetectorDoesNotInvokeHandler() {
        var shakeCount = 0
        let controller = ShakeViewController(isEnabled: false) {
            shakeCount += 1
        }

        controller.motionEnded(.motionShake, with: nil)

        XCTAssertEqual(shakeCount, 0)
    }
}

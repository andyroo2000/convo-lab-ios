import XCTest
@testable import ConvoLab

@MainActor
final class InteractivePopGestureGuardTests: XCTestCase {
    func testDisabledGuardHandlesAccessibilityEscapeThroughSessionExit() {
        var escapeCount = 0
        let controller = InteractivePopGestureGuard.Controller {
            escapeCount += 1
        }
        controller.update(isDisabled: true) {
            escapeCount += 1
        }

        XCTAssertTrue(controller.accessibilityPerformEscape())
        XCTAssertEqual(escapeCount, 1)
    }
}

import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeAnalyticsMotionTests: XCTestCase {
    func testInitialPanUsesVelocityWhenTranslationIsNotAvailable() {
        for horizontalVelocity in [-204.0, 220.0] {
            XCTAssertTrue(StudyTimeSwipeRecognition.isHorizontal(
                translation: .zero, velocity: CGPoint(x: horizontalVelocity, y: 0)
            ))
        }
        XCTAssertFalse(StudyTimeSwipeRecognition.isHorizontal(
            translation: .zero, velocity: CGPoint(x: 0, y: -204)
        ))
        XCTAssertFalse(StudyTimeSwipeRecognition.isHorizontal(
            translation: .zero, velocity: CGPoint(x: 204, y: 204)
        ))
        XCTAssertFalse(StudyTimeSwipeRecognition.isHorizontal(translation: .zero))
        XCTAssertFalse(StudyTimeSwipeRecognition.isHorizontal(
            translation: CGPoint(x: 1, y: 8), velocity: CGPoint(x: 220, y: 0)
        ))
    }

    func testSupersededTaskDoesNotStartItsRequest() async {
        let motion = StudyTimeAnalyticsMotion()
        var staleRequestCount = 0
        let currentFinished = expectation(description: "Current navigation ran")
        motion.startNavigation { _ in staleRequestCount += 1 }
        motion.startNavigation { generation in
            motion.finishNavigation(generation)
            currentFinished.fulfill()
        }

        await fulfillment(of: [currentFinished], timeout: 2)

        XCTAssertEqual(staleRequestCount, 0)
        XCTAssertFalse(motion.isSettling)
    }

    func testCancellationRejectsLateSelectionAndRestoresInteraction() async {
        let motion = StudyTimeAnalyticsMotion()
        let pending = PendingAnalyticsNavigation()
        motion.startNavigation(settling: true) { generation in
            await pending.wait()
            pending.wasCancelled = Task.isCancelled
            motion.finishNavigation(generation) { pending.didCommit = true }
            pending.finished.fulfill()
        }
        await fulfillment(of: [pending.started], timeout: 2)
        motion.dragOffset = -140
        motion.isLoading = true

        motion.cancelNavigation()
        pending.resume()
        await fulfillment(of: [pending.finished], timeout: 2)

        XCTAssertTrue(pending.wasCancelled)
        XCTAssertFalse(pending.didCommit)
        XCTAssertEqual(motion.dragOffset, 0)
        XCTAssertFalse(motion.isSettling)
        XCTAssertFalse(motion.isLoading)
    }

    func testSupersededCompletionCannotResetTheNewNavigation() async {
        let motion = StudyTimeAnalyticsMotion()
        let previous = PendingAnalyticsNavigation()
        let current = PendingAnalyticsNavigation()
        start(previous, motion: motion)
        await fulfillment(of: [previous.started], timeout: 2)
        start(current, motion: motion)
        await fulfillment(of: [current.started], timeout: 2)
        motion.dragOffset = 80
        motion.isLoading = true

        previous.resume()
        await fulfillment(of: [previous.finished], timeout: 2)

        XCTAssertFalse(previous.didCommit)
        XCTAssertTrue(motion.isSettling)
        XCTAssertTrue(motion.isLoading)
        XCTAssertEqual(motion.dragOffset, 80)

        current.resume()
        await fulfillment(of: [current.finished], timeout: 2)
        XCTAssertTrue(current.didCommit)
        XCTAssertFalse(motion.isSettling)
        XCTAssertFalse(motion.isLoading)
        XCTAssertEqual(motion.dragOffset, 0)
    }

    private func start(_ pending: PendingAnalyticsNavigation, motion: StudyTimeAnalyticsMotion) {
        motion.startNavigation(settling: true) { generation in
            await pending.wait()
            motion.finishNavigation(generation) { pending.didCommit = true }
            pending.finished.fulfill()
        }
    }
}

@MainActor
private final class PendingAnalyticsNavigation {
    let started = XCTestExpectation(description: "Navigation started")
    let finished = XCTestExpectation(description: "Navigation finished")
    var wasCancelled = false
    var didCommit = false
    private var continuation: CheckedContinuation<Void, Never>?

    nonisolated deinit {}

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

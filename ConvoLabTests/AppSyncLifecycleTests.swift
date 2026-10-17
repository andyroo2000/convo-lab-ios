import XCTest
@testable import ConvoLab

@MainActor
final class AppSyncLifecycleTests: XCTestCase {
    func testConcurrentStartsShareOneOperation() async {
        let lifecycle = AppSyncLifecycle()
        let gate = SyncLifecycleTestGate()
        let started = expectation(description: "Startup began")
        var starts = 0
        let first = Task {
            await lifecycle.start {
                starts += 1
                started.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let joined = expectation(description: "Second startup joined")
        let second = Task {
            joined.fulfill()
            await lifecycle.start { starts += 1 }
        }
        await fulfillment(of: [joined], timeout: 1)
        XCTAssertFalse(lifecycle.hasStarted)
        gate.open()
        await first.value
        await second.value
        await lifecycle.start { starts += 1 }
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(lifecycle.hasStarted)
    }

    func testStudySurfaceWaitsForStartupBeforeRefreshing() async {
        let lifecycle = AppSyncLifecycle()
        await assertSerialOrder(
            lifecycle: lifecycle,
            firstOperation: lifecycle.start,
            followingRefresh: .studySurface(account(42))
        )
    }

    func testConcurrentForegroundRefreshesJoinButNextActivationRetries() async {
        let lifecycle = AppSyncLifecycle()
        let gate = SyncLifecycleTestGate()
        let started = expectation(description: "Refresh began")
        var refreshes = 0
        let first = Task {
            await lifecycle.refresh(.foreground(self.account(42))) {
                refreshes += 1
                started.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let waiting = expectation(description: "Refresh joined")
        let second = Task {
            waiting.fulfill()
            await lifecycle.refresh(.foreground(self.account(42))) { refreshes += 1 }
        }
        await fulfillment(of: [waiting], timeout: 1)
        gate.open()
        await first.value
        await second.value
        XCTAssertEqual(refreshes, 1)
        // A failed operation has no artificial freshness window in this owner.
        await lifecycle.refresh(.foreground(self.account(42))) { refreshes += 1 }
        XCTAssertEqual(refreshes, 2)
    }

    func testAuthenticatedRefreshSatisfiesConcurrentForegroundRequest() async {
        let lifecycle = AppSyncLifecycle()
        let gate = SyncLifecycleTestGate()
        let started = expectation(description: "Authenticated refresh began")
        var foregroundRefreshes = 0
        let full = Task {
            await lifecycle.refresh(.authenticated(self.account(42))) {
                started.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let waiting = expectation(description: "Foreground joined")
        let foreground = Task {
            waiting.fulfill()
            await lifecycle.refresh(.foreground(self.account(42))) { foregroundRefreshes += 1 }
        }
        await fulfillment(of: [waiting], timeout: 1)
        gate.open()
        await full.value
        await foreground.value
        XCTAssertEqual(foregroundRefreshes, 0)
    }

    func testDifferentAccountWaitsThenRunsItsOwnRefresh() async {
        let lifecycle = AppSyncLifecycle()
        await assertSerialOrder(
            lifecycle: lifecycle,
            firstOperation: { await lifecycle.refresh(.authenticated(self.account(42)), operation: $0) },
            followingRefresh: .authenticated(account(84))
        )
    }

    func testNewCredentialsForSameAccountDoNotJoinStaleRefresh() async {
        let lifecycle = AppSyncLifecycle()
        await assertSerialOrder(
            lifecycle: lifecycle,
            firstOperation: { await lifecycle.refresh(.authenticated(self.account(42)), operation: $0) },
            followingRefresh: .authenticated(account(42, credential: "new-session"))
        )
    }

    func testCancelledViewDoesNotCancelSharedEssentialRefresh() async {
        let lifecycle = AppSyncLifecycle()
        let gate = SyncLifecycleTestGate()
        let started = expectation(description: "Refresh began")
        var operationWasCancelled = true
        let viewTask = Task {
            await lifecycle.refresh(.authenticated(self.account(42))) {
                started.fulfill()
                await gate.wait()
                operationWasCancelled = Task.isCancelled
            }
        }
        await fulfillment(of: [started], timeout: 1)
        viewTask.cancel()
        gate.open()
        await viewTask.value
        XCTAssertFalse(operationWasCancelled)
    }

    private func account(_ userID: Int, credential: String = "first-session") -> AppSyncLifecycle.Account {
        .init(userID: userID, credential: credential)
    }

    private func assertSerialOrder(
        lifecycle: AppSyncLifecycle,
        firstOperation: @escaping (@escaping @MainActor () async -> Void) async -> Void,
        followingRefresh: AppSyncLifecycle.Refresh
    ) async {
        let gate = SyncLifecycleTestGate()
        let started = expectation(description: "First operation began")
        var events: [String] = []
        let first = Task {
            await firstOperation {
                started.fulfill()
                await gate.wait()
                events.append("first")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let waiting = expectation(description: "Following refresh waiting")
        let following = Task {
            waiting.fulfill()
            await lifecycle.refresh(followingRefresh) { events.append("following") }
        }
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertTrue(events.isEmpty)
        gate.open()
        await first.value
        await following.value
        XCTAssertEqual(events, ["first", "following"])
    }

}

@MainActor
private final class SyncLifecycleTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

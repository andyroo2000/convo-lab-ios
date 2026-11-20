import XCTest
@testable import ConvoLab

@MainActor
final class JournalLearningQueueTests: XCTestCase {
    func testResetWaitsForEarlierConfirmationsAndPrecedesLaterOnes() async throws {
        let queue = JournalLearningQueue()
        var events: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let first = queue.enqueue {
            await withCheckedContinuation { release = $0 }
            events.append("first confirmation")
        }
        while release == nil { await Task.yield() }
        let second = queue.enqueue { events.append("second confirmation") }
        let reset = queue.enqueue { events.append("reset") }
        let later = queue.enqueue { events.append("later confirmation") }
        await Task.yield()
        XCTAssertTrue(events.isEmpty)
        release?.resume()
        for task in [first, second, reset, later] { try await task.value }
        XCTAssertEqual(events, ["first confirmation", "second confirmation", "reset", "later confirmation"])
    }

    func testFailedConfirmationDoesNotPreventReset() async throws {
        let queue = JournalLearningQueue()
        let failed = queue.enqueue { throw CocoaError(.fileWriteNoPermission) }
        var cleared = false
        let reset = queue.enqueue { cleared = true }
        do { try await failed.value; XCTFail("Expected the storage error") } catch { }
        try await reset.value
        XCTAssertTrue(cleared)
    }
}

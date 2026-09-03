import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testNewCardQueueLoadMoreDoesNotStartDuringReorder() async throws {
        let first = makeQueueItem(id: "first", position: 1)
        let second = makeQueueItem(id: "second", position: 2)
        let third = makeQueueItem(id: "third", position: 3)

        for reorderStatus in [200, 500] {
            OverlappingQueueReorderURLProtocol.configure(
                initialPage: try queuePage(items: [first, second], total: 3, nextCursor: "next"), refreshedPage: Data(),
                reorderPage: try queuePage(items: [second, first], total: 3, nextCursor: "next"),
                reorderStatus: reorderStatus, nextPage: try queuePage(items: [third], total: 3, nextCursor: nil))
            let store = try makeStore(protocolClass: OverlappingQueueReorderURLProtocol.self)
            try await store.refreshNewCardQueue()

            let reorder = Task { () -> Error? in
                do {
                    try await store.moveNewCards(fromOffsets: IndexSet(integer: 1), toOffset: 0)
                    return nil
                } catch { return error }
            }
            await waitUntil { OverlappingQueueReorderURLProtocol.hasPendingReorder }
            XCTAssertTrue(OverlappingQueueReorderURLProtocol.hasPendingReorder)
            let loadMore = Task { () -> Error? in
                do {
                    try await store.loadMoreNewCardQueue()
                    return nil
                } catch { return error }
            }
            for _ in 0..<10 where !OverlappingQueueReorderURLProtocol.hasPendingLoadMore {
                try await Task.sleep(for: .milliseconds(10))
            }

            XCTAssertFalse(OverlappingQueueReorderURLProtocol.hasPendingLoadMore)
            OverlappingQueueReorderURLProtocol.releasePendingLoadMore()
            let loadMoreError = await loadMore.value
            XCTAssertNil(loadMoreError)
            OverlappingQueueReorderURLProtocol.releasePendingReorder()
            let reorderError = await reorder.value

            if reorderStatus == 200 {
                XCTAssertNil(reorderError)
                XCTAssertEqual(store.newCardQueue.map(\.id), [second.id, first.id])
            } else {
                XCTAssertNotNil(reorderError)
                XCTAssertEqual(store.newCardQueue.map(\.id), [first.id, second.id])
            }
            XCTAssertEqual(store.newCardQueueNextCursor, "next")
        }
    }
}

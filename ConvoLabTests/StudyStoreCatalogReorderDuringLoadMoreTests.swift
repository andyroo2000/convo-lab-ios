import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testNewCardQueueReorderDoesNotStartDuringLoadMore() async throws {
        let first = makeQueueItem(id: "first", position: 1)
        let second = makeQueueItem(id: "second", position: 2)
        let third = makeQueueItem(id: "third", position: 3)

        for loadMoreStatus in [200, 500] {
            OverlappingQueueReorderURLProtocol.configure(.init(
                initialPage: try queuePage(items: [first, second], total: 3, nextCursor: "next"), refreshedPage: Data(),
                reorderPage: try queuePage(items: [second, first], total: 3, nextCursor: "next"), reorderStatus: 200,
                nextPage: try queuePage(items: [third], total: 3, nextCursor: nil), nextPageStatus: loadMoreStatus))
            let store = try makeStore(protocolClass: OverlappingQueueReorderURLProtocol.self)
            try await store.refreshNewCardQueue()

            let loadMore = Task { () -> Error? in
                do {
                    try await store.loadMoreNewCardQueue()
                    return nil
                } catch { return error }
            }
            await waitUntil { OverlappingQueueReorderURLProtocol.hasPendingLoadMore }
            XCTAssertTrue(OverlappingQueueReorderURLProtocol.hasPendingLoadMore)
            let reorder = Task { () -> Error? in
                do {
                    try await store.moveNewCards(fromOffsets: IndexSet(integer: 1), toOffset: 0)
                    return nil
                } catch { return error }
            }
            for _ in 0..<10 where !OverlappingQueueReorderURLProtocol.hasPendingReorder {
                try await Task.sleep(for: .milliseconds(10))
            }

            XCTAssertFalse(OverlappingQueueReorderURLProtocol.hasPendingReorder)
            OverlappingQueueReorderURLProtocol.releasePendingReorder()
            let reorderError = await reorder.value
            XCTAssertNil(reorderError)
            OverlappingQueueReorderURLProtocol.releasePendingLoadMore()
            let loadMoreError = await loadMore.value

            if loadMoreStatus == 200 {
                XCTAssertNil(loadMoreError)
                XCTAssertEqual(store.newCardQueue.map(\.id), [first.id, second.id, third.id])
                XCTAssertNil(store.newCardQueueNextCursor)
            } else {
                XCTAssertNotNil(loadMoreError)
                XCTAssertEqual(store.newCardQueue.map(\.id), [first.id, second.id])
                XCTAssertEqual(store.newCardQueueNextCursor, "next")
            }
        }
    }
}

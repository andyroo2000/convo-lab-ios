import XCTest
@testable import ConvoLab

@MainActor
final class JournalArchiveRefreshTests: XCTestCase {
    private var root: URL!
    private var store: JournalStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: config))
        api.setAccessToken("sync-fixture")
        store = JournalStore(api: api, userID: 1, storageRoot: root)
        MockURLProtocol.deferredHandler = nil
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testCancelledArchiveRequestDoesNotShowServiceError() async {
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await store.loadMore(refresh: true)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
        let cancelled = Task { await store.loadMore(refresh: true) }
        cancelled.cancel()
        await cancelled.value
        XCTAssertNil(store.errorMessage)
    }

    func testForegroundRefreshQueuesBehindPaginationAndRestartsFromFirstPage() async throws {
        try await queuedRefresh(cancelOlderRequest: false)
    }

    func testForegroundRefreshSurvivesCancellationOfOlderSheetTask() async throws {
        try await queuedRefresh(cancelOlderRequest: true)
    }

    private func queuedRefresh(cancelOlderRequest: Bool) async throws {
        let old = JournalEntry(id: JournalDraft.new().id, body: "古い文章。", entryDate: "2026-11-22", version: 1, createdAt: "now", updatedAt: "now")
        let initial = try response(JournalArchivePage(data: [old], nextCursor: "older-page"))
        MockURLProtocol.handler = { _ in initial }
        await store.loadMore(refresh: true)
        let pending = LockedDeferredResponse()
        MockURLProtocol.deferredHandler = { request, completion in
            XCTAssertTrue(request.url!.absoluteString.contains("cursor=older-page"))
            pending.hold(completion)
        }
        let pagination = Task { await store.loadMore() }
        await pending.waitUntilPending()
        await store.loadMore(refresh: true)
        // The old root was deleted remotely. Restart the archive rather than appending.
        let refreshed = expectation(description: "Queued first-page request")
        let next = try response(JournalArchivePage(data: [], nextCursor: "new-page"))
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            XCTAssertNil(request.url!.query)
            refreshed.fulfill()
            return next
        }
        if cancelOlderRequest { pagination.cancel() }
        else { pending.succeed(with: try response(JournalArchivePage(data: [], nextCursor: nil))) }
        await pagination.value
        await fulfillment(of: [refreshed], timeout: 2)
        for _ in 0..<100 where store.nextCursor != "new-page" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.nextCursor, "new-page")
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    private func response(_ page: JournalArchivePage) throws -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: "https://journal.test/api/journal/entries")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(page))
    }
}

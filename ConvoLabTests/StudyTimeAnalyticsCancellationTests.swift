import Foundation
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testCancelledAnalyticsRequestsPreserveTheVisibleChartWithoutReportingErrors() async throws {
        for prefetch in [false, true] {
            for fails in [false, true] {
                try await assertCancelledAnalytics(prefetch: prefetch, fails: fails)
            }
        }
    }

    private func assertCancelledAnalytics(prefetch: Bool, fails: Bool) async throws {
        let started = expectation(description: "Historical request started")
        let delivered = expectation(description: "Cancelled transport completed")
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            let response = Result { try analyticsResponse(for: request) }
            let anchor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "anchorDate" }?.value
            guard anchor == "2026-06-15" else {
                completion(response)
                return
            }
            started.fulfill()
            Task {
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
                completion(fails ? .failure(URLError(.timedOut)) : response)
                delivered.fulfill()
            }
        }
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let store = StudyTimeStore(
            api: client, context: container.mainContext, snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        store.activate(userID: 42)
        let currentAnchor = try Date("2026-06-16T12:00:00Z", strategy: .iso8601)
        let currentLoaded = await store.loadAnalytics(anchorDate: currentAnchor)
        XCTAssertTrue(currentLoaded)
        let current = try XCTUnwrap(store.analytics)
        let historicalAnchor = try Date("2026-06-15T12:00:00Z", strategy: .iso8601)
        let request = Task {
            if prefetch {
                return await store.prefetchAnalytics(anchorDate: historicalAnchor, reportFailure: true)
            }
            return await store.loadAnalytics(anchorDate: historicalAnchor)
        }
        await fulfillment(of: [started], timeout: 2)

        request.cancel()
        continuation.yield()
        let loaded = await request.value
        await fulfillment(of: [delivered], timeout: 2)

        XCTAssertFalse(loaded)
        XCTAssertEqual(store.analytics, current)
        XCTAssertNil(store.cachedAnalytics(anchorDate: historicalAnchor))
        XCTAssertNil(store.syncErrorMessage)
    }
}

import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testFailedAnchoredAnalyticsRequestPreservesCurrentChart() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            if request.url?.path == "/api/study/activity-analytics" {
                let components = try XCTUnwrap(
                    URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                )
                let anchorDate = components.queryItems?
                    .first { $0.name == "anchorDate" }?.value
                if anchorDate == "2026-06-15" {
                    return (
                        HTTPURLResponse(
                            url: try XCTUnwrap(request.url),
                            statusCode: 500,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        Data(#"{"message":"Analytics unavailable"}"#.utf8)
                    )
                }
                return try analyticsResponse(for: request)
            }

            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("[]".utf8)
            )
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)
        await store.synchronize()
        let currentAnalytics = try XCTUnwrap(store.analytics)

        let loaded = await store.loadAnalytics(
            anchorDate: try Date("2026-06-15T12:00:00Z", strategy: .iso8601)
        )

        XCTAssertFalse(loaded)
        XCTAssertEqual(store.analytics, currentAnalytics)
        XCTAssertEqual(store.syncErrorMessage, "Analytics unavailable")

        await store.synchronize()

        XCTAssertEqual(store.analytics, currentAnalytics)
        XCTAssertNil(store.syncErrorMessage)
    }

    func testPrefetchedAnalyticsCanBeSelectedWithoutChangingTheVisibleChartEarly() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            if request.url?.path == "/api/study/activity-analytics" {
                let requestedAnchor = URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first { $0.name == "anchorDate" }?.value
                if requestedAnchor == "2026-06-15" {
                    return try analyticsResponse(
                        for: request,
                        anchorDateOverride: "2026-06-14"
                    )
                }
                return try analyticsResponse(for: request)
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("[]".utf8)
            )
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)
        await store.synchronize()
        let visibleAnchor = try XCTUnwrap(store.analytics?.anchorDate)
        let nextAnchor = try Date("2026-06-15T12:00:00Z", strategy: .iso8601)

        let prefetched = await store.prefetchAnalytics(anchorDate: nextAnchor)

        XCTAssertTrue(prefetched)
        XCTAssertEqual(store.analytics?.anchorDate, visibleAnchor)
        XCTAssertNotNil(store.cachedAnalytics(anchorDate: nextAnchor))

        XCTAssertTrue(store.selectCachedAnalytics(anchorDate: nextAnchor))
        XCTAssertEqual(store.analytics?.anchorDate, "2026-06-14")

        await store.synchronize()

        XCTAssertNil(store.cachedAnalytics(anchorDate: nextAnchor))
    }

    func testLoadedAnalyticsUsesTheServerConfirmedAnchorForLaterSynchronization() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let confirmedAnchorRequest = expectation(description: "Uses confirmed analytics anchor")
        let client = makeClient { request in
            if request.url?.path == "/api/study/activity-analytics" {
                let requestedAnchor = URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first { $0.name == "anchorDate" }?.value
                if requestedAnchor == "2026-06-15" {
                    return try analyticsResponse(
                        for: request,
                        anchorDateOverride: "2026-06-14"
                    )
                }
                if requestedAnchor == "2026-06-14" {
                    confirmedAnchorRequest.fulfill()
                }
                return try analyticsResponse(for: request)
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("[]".utf8)
            )
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        let loaded = await store.loadAnalytics(
            anchorDate: try Date("2026-06-15T12:00:00Z", strategy: .iso8601)
        )
        await store.synchronize()
        await fulfillment(of: [confirmedAnchorRequest], timeout: 1)

        XCTAssertTrue(loaded)
    }

    func testCacheInvalidationDiscardsAnOlderInFlightPrefetch() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let (prefetchStarted, prefetchStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePrefetch, releasePrefetchContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            do {
                guard request.url?.path == "/api/study/activity-analytics" else {
                    completion(.failure(URLError(.badURL)))
                    return
                }
                let requestedAnchor = URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first { $0.name == "anchorDate" }?.value
                if requestedAnchor == "2026-06-15" {
                    prefetchStartedContinuation.yield()
                    Task {
                        var releaseIterator = releasePrefetch.makeAsyncIterator()
                        _ = await releaseIterator.next()
                        completion(.success(try analyticsResponse(for: request)))
                    }
                } else {
                    completion(.success(try analyticsResponse(for: request)))
                }
            } catch {
                completion(.failure(error))
            }
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)
        let staleAnchor = try Date("2026-06-15T12:00:00Z", strategy: .iso8601)
        let currentAnchor = try Date("2026-06-16T12:00:00Z", strategy: .iso8601)
        let stalePrefetch = Task {
            await store.prefetchAnalytics(anchorDate: staleAnchor)
        }
        var startedIterator = prefetchStarted.makeAsyncIterator()
        _ = await startedIterator.next()

        let currentLoaded = await store.loadAnalytics(anchorDate: currentAnchor)

        XCTAssertTrue(currentLoaded)
        releasePrefetchContinuation.yield()
        let stalePrefetchSucceeded = await stalePrefetch.value

        XCTAssertFalse(stalePrefetchSucceeded)
        XCTAssertNil(store.cachedAnalytics(anchorDate: staleAnchor))
        XCTAssertEqual(store.analytics?.anchorDate, "2026-06-16")
    }

}

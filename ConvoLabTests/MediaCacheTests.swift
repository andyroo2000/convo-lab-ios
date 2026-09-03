import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class MediaCacheTests: XCTestCase {
    @MainActor
    func testPreparationDownloadsStudyMediaInBoundedBatches() async throws {
        let paths = LockedRequestPaths()
        let batchSizes = LockedRequestPaths()
        installSuccessfulBatchHandler(paths: paths, batchSizes: batchSizes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let diagnosticsSink = RecordingNativeDiagnosticsSink()
        let cache = MediaCache(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            diagnostics: NativeDiagnostics(sink: diagnosticsSink)
        )
        let urls = (0..<45).map { offset in
            let id = ClientIdentifier.ulid(
                date: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + offset))
            )
            return URL(string: "/api/study/media/\(id)")!
        }

        await cache.prepare(urls: urls, category: "offline-study")

        XCTAssertEqual(
            paths.values,
            Array(repeating: "/api/study/media/batch", count: 3)
        )
        XCTAssertEqual(batchSizes.values.sorted(), ["20", "20", "5"])
        XCTAssertEqual(cache.cachedKeys(for: urls).count, 45)
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            45
        )

        let additionalURLs = (45..<50).map { offset in
            let id = ClientIdentifier.ulid(
                date: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + offset))
            )
            return URL(string: "/api/study/media/\(id)")!
        }

        await cache.prepare(urls: urls + additionalURLs, category: "offline-study")
        // Repeating an already-complete preparation must not emit an empty interval.
        await cache.prepare(urls: urls + additionalURLs, category: "offline-study")

        XCTAssertEqual(
            paths.values,
            Array(repeating: "/api/study/media/batch", count: 4)
        )
        XCTAssertEqual(batchSizes.values.sorted(), ["20", "20", "5", "5"])
        XCTAssertEqual(cache.cachedKeys(for: urls + additionalURLs).count, 50)
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            50
        )
        assertSuccessfulPreparationDiagnostics(diagnosticsSink)
    }

    @MainActor
    func testPreparationFailureEmitsPairedFailedDiagnostics() async throws {
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let diagnosticsSink = RecordingNativeDiagnosticsSink()
        let cache = MediaCache(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            diagnostics: NativeDiagnostics(sink: diagnosticsSink)
        )
        let id = ClientIdentifier.ulid()

        await cache.prepare(
            urls: [URL(string: "/api/study/media/\(id)")!],
            category: "offline-study"
        )

        XCTAssertEqual(diagnosticsSink.events.map(\.stage), [.began, .ended])
        XCTAssertEqual(diagnosticsSink.events.last?.outcome, .failed)
        XCTAssertEqual(diagnosticsSink.events.last?.itemCount, 1)
    }

    @MainActor
    func testMissingBatchEndpointDoesNotFloodLegacyServerWithIndividualRequests() async throws {
        let requestCounter = LockedCounter()
        MockURLProtocol.handler = { request in
            _ = requestCounter.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"Not Found"}"#.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let diagnosticsSink = RecordingNativeDiagnosticsSink()
        let cache = MediaCache(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            diagnostics: NativeDiagnostics(sink: diagnosticsSink)
        )
        let urls = (0..<20).map { offset in
            let id = ClientIdentifier.ulid(
                date: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + offset))
            )

            return URL(string: "/api/study/media/\(id)")!
        }

        await cache.prepare(urls: urls, category: "offline-study")

        XCTAssertEqual(requestCounter.current, 1)
        XCTAssertTrue(cache.cachedKeys(for: urls).isEmpty)
        XCTAssertEqual(diagnosticsSink.events.map(\.stage), [.began, .ended])
        XCTAssertEqual(diagnosticsSink.events.last?.outcome, .discarded)
    }

    @MainActor
    func testBatchResponseCannotBeCachedUnderANewlyActivatedAccount() async throws {
        try await assertInFlightPreparationIsInvalidated { cache in
            cache.activate(userID: 2)
        }
    }

    @MainActor
    func testClearingDownloadedMediaInvalidatesInFlightBatchPreparation() async throws {
        try await assertInFlightPreparationIsInvalidated { cache in
            try cache.clearDownloadedMedia()
        }
    }

    @MainActor
    private func assertInFlightPreparationIsInvalidated(
        by invalidation: (MediaCache) throws -> Void
    ) async throws {
        let gate = LockedRequestGate()
        let id = ClientIdentifier.ulid()
        MockURLProtocol.handler = { request in
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: [
                    "items": [[
                        "id": id,
                        "mimeType": "audio/mpeg",
                        "data": Data("prepared-media".utf8).base64EncodedString(),
                    ]],
                ])
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        let cache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let remoteURL = URL(string: "/api/study/media/\(id)")!

        let preparation = Task {
            await cache.prepare(urls: [remoteURL], category: "offline-study")
        }
        for _ in 0..<100 where !gate.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.hasStarted)
        try invalidation(cache)
        gate.release()
        await preparation.value

        XCTAssertNil(cache.localURL(for: remoteURL))
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            0
        )
    }

    private func installSuccessfulBatchHandler(
        paths: LockedRequestPaths,
        batchSizes: LockedRequestPaths
    ) {
        MockURLProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            let body = try JSONSerialization.jsonObject(
                with: try requestBody(request)
            ) as? [String: Any]
            let ids = try XCTUnwrap(body?["ids"] as? [String])
            batchSizes.append(String(ids.count))
            let items = ids.map { id in
                [
                    "id": id,
                    "mimeType": "audio/mpeg",
                    "data": Data("bytes-\(id)".utf8).base64EncodedString(),
                ]
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: ["items": items])
            )
        }
    }

    private func assertSuccessfulPreparationDiagnostics(
        _ diagnosticsSink: RecordingNativeDiagnosticsSink
    ) {
        XCTAssertEqual(
            diagnosticsSink.events,
            [
                .init(
                    operation: .mediaPreparation,
                    stage: .began,
                    outcome: nil,
                    reason: nil,
                    itemCount: 45
                ),
                .init(
                    operation: .mediaPreparation,
                    stage: .ended,
                    outcome: .succeeded,
                    reason: nil,
                    itemCount: 45
                ),
                .init(
                    operation: .mediaPreparation,
                    stage: .began,
                    outcome: nil,
                    reason: nil,
                    itemCount: 5
                ),
                .init(
                    operation: .mediaPreparation,
                    stage: .ended,
                    outcome: .succeeded,
                    reason: nil,
                    itemCount: 5
                ),
            ]
        )
    }
}

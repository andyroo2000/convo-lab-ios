import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class MediaCacheTests: XCTestCase {
    @MainActor
    func testPreparationDownloadsStudyMediaInBoundedBatches() async throws {
        let paths = LockedRequestPaths()
        let batchSizes = LockedRequestPaths()
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
        let cache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let urls = (0..<20).map { offset in
            let id = ClientIdentifier.ulid(
                date: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + offset))
            )

            return URL(string: "/api/study/media/\(id)")!
        }

        await cache.prepare(urls: urls, category: "offline-study")

        XCTAssertEqual(requestCounter.current, 1)
        XCTAssertTrue(cache.cachedKeys(for: urls).isEmpty)
    }

    @MainActor
    func testBatchResponseCannotBeCachedUnderANewlyActivatedAccount() async throws {
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
                        "data": Data("first-user-media".utf8).base64EncodedString(),
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
        cache.activate(userID: 2)
        gate.release()
        await preparation.value

        XCTAssertNil(cache.localURL(for: remoteURL))
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            0
        )
    }

    @MainActor
    func testClearingDownloadedMediaInvalidatesInFlightBatchPreparation() async throws {
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
                        "data": Data("cleared-media".utf8).base64EncodedString(),
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
        try cache.clearDownloadedMedia()
        gate.release()
        await preparation.value

        XCTAssertNil(cache.localURL(for: remoteURL))
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            0
        )
    }

    @MainActor
    func testChangingSignatureReusesStableMediaCacheEntry() async throws {
        let requestCounter = LockedCounter()
        MockURLProtocol.handler = { request in
            _ = requestCounter.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("audio".utf8)
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

        let first = try await cache.download(
            URL(string: "https://cdn.example/audio/track.mp3?signature=first&expires=1")!,
            category: "daily-audio"
        )
        let second = try await cache.download(
            URL(string: "https://cdn.example/audio/track.mp3?signature=second&expires=2")!,
            category: "daily-audio"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(requestCounter.current, 1)
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            1
        )
    }

    @MainActor
    func testRefreshReplacesExistingBytesForStableMediaURL() async throws {
        let requestCounter = LockedCounter()
        MockURLProtocol.handler = { request in
            let version = requestCounter.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("audio-\(version)".utf8)
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
        let remoteURL = URL(string: "/api/study/media/answer")!

        let first = try await cache.download(remoteURL, category: "active-study")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "audio-1")

        let refreshed = try await cache.refresh(remoteURL, category: "active-study")

        XCTAssertEqual(first, refreshed)
        XCTAssertEqual(try String(contentsOf: refreshed, encoding: .utf8), "audio-2")
        XCTAssertEqual(requestCounter.current, 2)
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            1
        )
    }

    @MainActor
    func testFailedRefreshKeepsPreviouslyCachedAudioPlayable() async throws {
        let requestCounter = LockedCounter()
        MockURLProtocol.handler = { request in
            guard requestCounter.next() == 1 else {
                throw URLError(.notConnectedToInternet)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("original-audio".utf8)
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
        let remoteURL = URL(string: "/api/study/media/answer")!
        let original = try await cache.download(remoteURL, category: "active-study")

        do {
            _ = try await cache.refresh(remoteURL, category: "active-study")
            XCTFail("Expected refresh to fail")
        } catch {
            // Expected.
        }

        XCTAssertEqual(
            try String(contentsOf: original, encoding: .utf8),
            "original-audio"
        )
        XCTAssertEqual(cache.localURL(for: remoteURL), original)
    }

    @MainActor
    func testOrdinaryDownloadJoinsForcedRefreshInsteadOfReturningStaleFile() async throws {
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("old-audio".utf8)
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
        let remoteURL = URL(string: "/api/study/media/answer")!
        _ = try await cache.download(remoteURL, category: "active-study")

        let gate = LockedRequestGate()
        let refreshRequests = LockedCounter()
        MockURLProtocol.handler = { request in
            _ = refreshRequests.next()
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("fresh-audio".utf8)
            )
        }
        let refresh = Task {
            try await cache.refresh(remoteURL, category: "active-study")
        }
        for _ in 0..<100 where !gate.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        let completion = MediaDownloadCompletion()
        let ordinaryDownload = Task {
            let url = try await cache.download(remoteURL, category: "active-study")
            await completion.markCompleted()
            return url
        }
        try await Task.sleep(for: .milliseconds(25))

        let completedBeforeRefresh = await completion.isCompleted
        XCTAssertFalse(completedBeforeRefresh)
        gate.release()
        let refreshedURL = try await refresh.value
        let ordinaryURL = try await ordinaryDownload.value

        XCTAssertEqual(ordinaryURL, refreshedURL)
        XCTAssertEqual(refreshRequests.current, 1)
        XCTAssertEqual(
            try String(contentsOf: ordinaryURL, encoding: .utf8),
            "fresh-audio"
        )
    }

    @MainActor
    func testReadinessSnapshotDoesNotUpdateMediaAccessTime() async throws {
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("audio".utf8)
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
        let remoteURL = URL(string: "https://cdn.example/audio/track.mp3")!
        _ = try await cache.download(remoteURL, category: "active-study")
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<CachedMediaRecord>()).first
        )
        let previousAccess = Date(timeIntervalSince1970: 1_000)
        record.lastAccessedAt = previousAccess
        try container.mainContext.save()

        let available = cache.cachedKeys(for: [remoteURL])

        XCTAssertEqual(available, [MediaCache.stableCacheKey(for: remoteURL)])
        XCTAssertEqual(record.lastAccessedAt, previousAccess)
    }

    @MainActor
    func testDownloadedByteCountExcludesDeferredDeletionRecords() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: .shared
        )
        let cache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        container.mainContext.insert(
            CachedMediaRecord(
                remoteURL: "active",
                userID: 1,
                relativePath: "active.mp3",
                byteCount: 10,
                category: "daily-audio"
            )
        )
        container.mainContext.insert(
            CachedMediaRecord(
                remoteURL: "retired",
                userID: 1,
                relativePath: "retired.mp3",
                byteCount: 20,
                category: "deferred-deletion"
            )
        )
        try container.mainContext.save()

        XCTAssertEqual(cache.totalByteCount, 10)
    }

    @MainActor
    func testAccountDeletionRemovesMediaFileBeforeAcknowledgingRecord() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: .shared
        )
        let cache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let filename = "account-deletion-\(UUID().uuidString).mp3"
        let fileURL = applicationSupport
            .appending(path: "OfflineMedia", directoryHint: .isDirectory)
            .appending(path: filename)
        try Data("deleted account media".utf8).write(to: fileURL)
        container.mainContext.insert(
            CachedMediaRecord(
                remoteURL: "deleted-account-media",
                userID: 1,
                relativePath: filename,
                byteCount: 21,
                category: "active-study"
            )
        )
        try container.mainContext.save()

        try await cache.deleteLocalDataForAccountDeletion(userID: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            0
        )
    }

    @MainActor
    func testAccountDeletionRetainsMediaRecordWhenFileRemovalFails() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: .shared
        )
        let cache = MediaCache(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            accountDeletionFileRemoval: { _ in false }
        )
        let record = CachedMediaRecord(
            remoteURL: "undeletable-account-media",
            userID: 1,
            relativePath: "undeletable.mp3",
            byteCount: 21,
            category: "active-study"
        )
        container.mainContext.insert(record)
        try container.mainContext.save()

        do {
            try await cache.deleteLocalDataForAccountDeletion(userID: 1)
            XCTFail("Expected failed file removal to keep cleanup pending")
        } catch {
            XCTAssertEqual(
                try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
                1
            )
        }
    }

    @MainActor
    func testDeferredDeletionRecordIsNotServedAsCacheHit() async throws {
        let requestCounter = LockedCounter()
        MockURLProtocol.handler = { request in
            let version = requestCounter.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("audio-\(version)".utf8)
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
        let remoteURL = URL(string: "/api/daily-audio/track")!
        let retiredKey = "daily-audio:track:1"
        _ = try await cache.download(
            remoteURL,
            category: "daily-audio",
            cacheKey: retiredKey
        )
        try cache.removeCachedItems(
            category: "daily-audio",
            cacheKeyPrefix: "daily-audio:track",
            keeping: "daily-audio:track:2"
        )

        XCTAssertNil(cache.localURL(for: remoteURL, cacheKey: retiredKey))
        XCTAssertTrue(cache.cachedKeys(for: [URL(string: retiredKey)!]).isEmpty)

        let refreshedURL = try await cache.download(
            remoteURL,
            category: "daily-audio",
            cacheKey: retiredKey
        )

        XCTAssertEqual(requestCounter.current, 2)
        XCTAssertEqual(
            try String(contentsOf: refreshedURL, encoding: .utf8),
            "audio-2"
        )
    }

    @MainActor
    func testAccountDeletionContinuesAfterOneMediaRemovalFails() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: .shared
        )
        let cache = MediaCache(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            accountDeletionFileRemoval: { url in url.lastPathComponent != "blocked.mp3" }
        )
        for relativePath in ["blocked.mp3", "removable.mp3"] {
            container.mainContext.insert(
                CachedMediaRecord(
                    remoteURL: relativePath,
                    userID: 1,
                    relativePath: relativePath,
                    byteCount: 21,
                    category: "active-study"
                )
            )
        }
        try container.mainContext.save()

        do {
            try await cache.deleteLocalDataForAccountDeletion(userID: 1)
            XCTFail("Expected one failed removal to keep the domain pending")
        } catch {
            let records = try container.mainContext.fetch(
                FetchDescriptor<CachedMediaRecord>()
            )
            XCTAssertEqual(records.map(\.relativePath), ["blocked.mp3"])
        }
    }

    @MainActor
    func testInitializationPurgesDeferredDeletionFromPreviousLaunch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let rootURL = applicationSupport.appending(
            path: "OfflineMedia",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let filename = "\(UUID().uuidString).mp3"
        let fileURL = rootURL.appending(path: filename)
        try Data("retired".utf8).write(to: fileURL)
        let record = CachedMediaRecord(
            remoteURL: "retired-from-previous-launch",
            userID: 1,
            relativePath: filename,
            byteCount: 7,
            category: "deferred-deletion"
        )
        record.lastAccessedAt = .distantPast
        container.mainContext.insert(record)
        try container.mainContext.save()
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: .shared
        )

        _ = MediaCache(initialUserID: 1, api: client, context: container.mainContext)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<CachedMediaRecord>()
            ),
            0
        )
    }
}

private actor MediaDownloadCompletion {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

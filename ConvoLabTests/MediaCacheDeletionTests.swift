import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension MediaCacheTests {
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

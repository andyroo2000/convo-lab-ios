import CryptoKit
import Foundation
import SwiftData

@Observable
final class MediaCache {
    private static let deferredDeletionCategory = "deferred-deletion"
    private static let processStartedAt = Date.now
    private static let batchSize = 20

    private let api: APIClient
    private let context: ModelContext
    private let rootURL: URL

    private(set) var activeDownloads = 0
    @ObservationIgnored private var activeUserID: Int?
    @ObservationIgnored private var inFlightDownloads: [String: Task<URL, Error>] = [:]
    @ObservationIgnored private var inFlightRefreshes: [String: Task<URL, Error>] = [:]

    init(initialUserID: Int? = nil, api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        rootURL = applicationSupport.appending(path: "OfflineMedia", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try? purgeDeferredDeletionsFromPreviousLaunch()
        if let initialUserID {
            activate(userID: initialUserID)
        }
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        inFlightDownloads.values.forEach { $0.cancel() }
        inFlightRefreshes.values.forEach { $0.cancel() }
        inFlightDownloads.removeAll()
        inFlightRefreshes.removeAll()
        activeUserID = userID
    }

    func deactivate() {
        inFlightDownloads.values.forEach { $0.cancel() }
        inFlightRefreshes.values.forEach { $0.cancel() }
        inFlightDownloads.removeAll()
        inFlightRefreshes.removeAll()
        activeUserID = nil
    }

    func localURL(for remoteURL: URL, cacheKey explicitCacheKey: String? = nil) -> URL? {
        guard let userID = activeUserID else { return nil }
        let cacheKey = explicitCacheKey ?? Self.stableCacheKey(for: remoteURL)
        var descriptor = FetchDescriptor<CachedMediaRecord>(
            predicate: #Predicate { $0.userID == userID && $0.remoteURL == cacheKey }
        )
        descriptor.fetchLimit = 1
        guard let record = try? context.fetch(descriptor).first else {
            return nil
        }
        // Retired revisions may remain on disk while an AVPlayer from this
        // process is still reading them, but they must never become cache hits.
        guard record.category != Self.deferredDeletionCategory else {
            return nil
        }
        let url = rootURL.appending(path: record.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            context.delete(record)
            try? context.save()
            return nil
        }
        record.lastAccessedAt = .now
        try? context.save()
        return url
    }

    @discardableResult
    func download(
        _ remoteURL: URL,
        category: String,
        cacheKey explicitCacheKey: String? = nil
    ) async throws -> URL {
        guard let userID = activeUserID else {
            throw CancellationError()
        }
        let cacheKey = explicitCacheKey ?? Self.stableCacheKey(for: remoteURL)
        let taskKey = "\(userID):\(cacheKey)"
        if let refresh = inFlightRefreshes[taskKey] {
            return try await refresh.value
        }
        if let existing = localURL(for: remoteURL, cacheKey: cacheKey) {
            return existing
        }

        if let existingDownload = inFlightDownloads[taskKey] {
            return try await existingDownload.value
        }

        let download = Task { @MainActor [self] in
            try await performDownload(
                remoteURL,
                category: category,
                cacheKey: cacheKey
            )
        }
        inFlightDownloads[taskKey] = download
        defer { inFlightDownloads[taskKey] = nil }
        return try await download.value
    }

    private func performDownload(
        _ remoteURL: URL,
        category: String,
        cacheKey: String
    ) async throws -> URL {
        guard let userID = activeUserID else {
            throw CancellationError()
        }
        activeDownloads += 1
        defer { activeDownloads -= 1 }

        let (temporaryURL, response) = try await api.download(remoteURL)
        do {
            try Task.checkCancellation()
            guard activeUserID == userID else {
                throw CancellationError()
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        return try persistTemporaryFile(
            temporaryURL,
            mimeType: response.mimeType,
            remoteURL: remoteURL,
            category: category,
            cacheKey: cacheKey,
            userID: userID
        )
    }

    private func persistTemporaryFile(
        _ temporaryURL: URL,
        mimeType: String?,
        remoteURL: URL,
        category: String,
        cacheKey: String,
        userID: Int
    ) throws -> URL {
        guard activeUserID == userID else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw CancellationError()
        }
        let mimeExtension = mimeType.flatMap(Self.fileExtension(for:))
        let remoteExtension = remoteURL.pathExtension.isEmpty ? nil : remoteURL.pathExtension
        let fileExtension = mimeExtension ?? remoteExtension ?? "bin"
        let digest = SHA256.hash(data: Data("\(userID):\(cacheKey)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let filename = "\(digest).\(fileExtension)"
        let destination = rootURL.appending(path: filename)

        if FileManager.default.fileExists(atPath: destination.path) {
            // Atomic replacement keeps already-open reader handles valid while
            // ensuring a retired exact-key retry receives the newly fetched bytes.
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var descriptor = FetchDescriptor<CachedMediaRecord>(
            predicate: #Predicate { $0.userID == userID && $0.remoteURL == cacheKey }
        )
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            let previousURL = rootURL.appending(path: record.relativePath)
            record.relativePath = filename
            record.byteCount = bytes
            record.category = category
            record.lastAccessedAt = .now
            if previousURL != destination {
                try? FileManager.default.removeItem(at: previousURL)
            }
        } else {
            context.insert(CachedMediaRecord(
                remoteURL: cacheKey,
                userID: userID,
                relativePath: filename,
                byteCount: bytes,
                category: category
            ))
        }
        try context.save()
        return destination
    }

    func prepare(urls: [URL], category: String) async {
        guard let userID = activeUserID else { return }
        let uniqueURLs = Array(Set(urls))
        let uncachedURLs = uniqueURLs.filter { localURL(for: $0) == nil }
        let batchable = uncachedURLs.compactMap { url -> (url: URL, id: String)? in
            guard let id = Self.studyMediaID(for: url) else { return nil }
            return (url, id)
        }
        var preparedBatchKeys: Set<String> = []
        var deferredBatchKeys: Set<String> = []

        for offset in stride(from: 0, to: batchable.count, by: Self.batchSize) {
            let end = min(offset + Self.batchSize, batchable.count)
            let chunk = Array(batchable[offset..<end])
            do {
                let response: StudyMediaBatchResponse = try await api.request(
                    "/api/study/media/batch",
                    method: "POST",
                    body: StudyMediaBatchRequest(ids: chunk.map(\.id))
                )
                guard activeUserID == userID else { return }
                let urlsByID = Dictionary(
                    chunk.map { ($0.id.lowercased(), $0.url) },
                    uniquingKeysWith: { first, _ in first }
                )
                for item in response.items {
                    guard
                        let remoteURL = urlsByID[item.id.lowercased()]
                    else {
                        continue
                    }
                    let cacheKey = Self.stableCacheKey(for: remoteURL)
                    let temporaryURL = FileManager.default.temporaryDirectory
                        .appending(path: UUID().uuidString)
                    do {
                        try item.data.write(to: temporaryURL, options: .atomic)
                        _ = try persistTemporaryFile(
                            temporaryURL,
                            mimeType: item.mimeType,
                            remoteURL: remoteURL,
                            category: category,
                            cacheKey: cacheKey,
                            userID: userID
                        )
                        preparedBatchKeys.insert(cacheKey)
                    } catch {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                }
            } catch let APIClientError.rejected(status, _)
                where [404, 405, 429].contains(status)
            {
                // Production may not have the batch endpoint yet, or its media
                // bucket may already be exhausted. Do not turn that condition
                // into a burst of individual requests that starves sync calls.
                deferredBatchKeys.formUnion(
                    chunk.map { Self.stableCacheKey(for: $0.url) }
                )
            } catch {
                // Other transient batch failures retain the individual-download
                // fallback so preparation remains best effort.
            }
        }

        for url in uncachedURLs where
            !preparedBatchKeys.contains(Self.stableCacheKey(for: url))
                && !deferredBatchKeys.contains(Self.stableCacheKey(for: url))
        {
            do {
                _ = try await download(url, category: category)
            } catch {
                // Preparation is best effort. The owning screen can still stream while online.
            }
        }
    }

    private static func studyMediaID(for url: URL) -> String? {
        let components = url.path.split(separator: "/")
        guard
            components.count == 4,
            components[0] == "api",
            components[1] == "study",
            components[2] == "media"
        else {
            return nil
        }
        let id = String(components[3])
        guard id.count == 26 else { return nil }
        return id.lowercased()
    }

    @discardableResult
    func refresh(_ remoteURL: URL, category: String) async throws -> URL {
        guard let userID = activeUserID else {
            throw CancellationError()
        }
        let cacheKey = Self.stableCacheKey(for: remoteURL)
        let taskKey = "\(userID):\(cacheKey)"
        if let refresh = inFlightRefreshes[taskKey] {
            return try await refresh.value
        }
        while let ordinaryDownload = inFlightDownloads[taskKey] {
            _ = try? await ordinaryDownload.value
        }
        if let refresh = inFlightRefreshes[taskKey] {
            return try await refresh.value
        }
        let refresh = Task { @MainActor [self] in
            try await performDownload(
                remoteURL,
                category: category,
                cacheKey: cacheKey
            )
        }
        inFlightRefreshes[taskKey] = refresh
        defer { inFlightRefreshes[taskKey] = nil }
        return try await refresh.value
    }

    func cachedKeys(for remoteURLs: [URL]) -> Set<String> {
        guard let userID = activeUserID else { return [] }
        let desiredKeys = Set(remoteURLs.map(Self.stableCacheKey(for:)))
        guard !desiredKeys.isEmpty else { return [] }

        let records = (try? context.fetch(
            FetchDescriptor<CachedMediaRecord>(
                predicate: #Predicate { $0.userID == userID }
            )
        )) ?? []
        var availableKeys: Set<String> = []
        var removedMissingRecord = false

        for record in records where
            record.category != Self.deferredDeletionCategory
                && desiredKeys.contains(record.remoteURL)
        {
            let url = rootURL.appending(path: record.relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                availableKeys.insert(record.remoteURL)
            } else {
                context.delete(record)
                removedMissingRecord = true
            }
        }

        if removedMissingRecord {
            try? context.save()
        }
        return availableKeys
    }

    func removeCachedItems(
        category: String,
        cacheKeyPrefix: String,
        keeping cacheKeyToKeep: String
    ) throws {
        guard let userID = activeUserID else { return }
        let desiredCategory = category
        let records = try context.fetch(
            FetchDescriptor<CachedMediaRecord>(
                predicate: #Predicate {
                    $0.userID == userID && $0.category == desiredCategory
                }
            )
        )
        for record in records where
            record.category == category
                && record.remoteURL.hasPrefix(cacheKeyPrefix)
                && record.remoteURL != cacheKeyToKeep
        {
            guard
                inFlightDownloads["\(userID):\(record.remoteURL)"] == nil,
                inFlightRefreshes["\(userID):\(record.remoteURL)"] == nil
            else {
                continue
            }
            // AVPlayer may still be reading this file. Retire it from normal
            // cache lookup now, then unlink it on a later process launch when
            // no player from this session can still hold the asset.
            record.category = Self.deferredDeletionCategory
            record.lastAccessedAt = .now
        }
        try context.save()
    }

    private func purgeDeferredDeletionsFromPreviousLaunch() throws {
        let records = try context.fetch(FetchDescriptor<CachedMediaRecord>())
        for record in records where
            record.category == Self.deferredDeletionCategory
                && record.lastAccessedAt < Self.processStartedAt
        {
            let url = rootURL.appending(path: record.relativePath)
            try? FileManager.default.removeItem(at: url)
            context.delete(record)
        }
        try context.save()
    }

    var totalByteCount: Int64 {
        guard let userID = activeUserID else { return 0 }
        let records = (try? context.fetch(
            FetchDescriptor<CachedMediaRecord>(
                predicate: #Predicate {
                    $0.userID == userID && $0.category != "deferred-deletion"
                }
            )
        )) ?? []
        return records.reduce(0) { $0 + $1.byteCount }
    }

    func clearDownloadedMedia() throws {
        guard let userID = activeUserID else { return }
        try deleteLocalData(userID: userID)
    }

    func deleteLocalData(userID: Int) throws {
        let taskPrefix = "\(userID):"
        let downloadKeys = inFlightDownloads.keys.filter { $0.hasPrefix(taskPrefix) }
        for key in downloadKeys {
            inFlightDownloads[key]?.cancel()
            inFlightDownloads[key] = nil
        }
        let refreshKeys = inFlightRefreshes.keys.filter { $0.hasPrefix(taskPrefix) }
        for key in refreshKeys {
            inFlightRefreshes[key]?.cancel()
            inFlightRefreshes[key] = nil
        }
        let records = try context.fetch(
            FetchDescriptor<CachedMediaRecord>(
                predicate: #Predicate { $0.userID == userID }
            )
        )
        for record in records {
            try? FileManager.default.removeItem(
                at: rootURL.appending(path: record.relativePath)
            )
            context.delete(record)
        }
        try context.save()
    }

    static func stableCacheKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? url.path
    }

    private static func fileExtension(for mimeType: String) -> String? {
        switch mimeType {
        case "audio/mpeg": "mp3"
        case "audio/mp4", "audio/x-m4a": "m4a"
        case "audio/wav", "audio/x-wav": "wav"
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/webp": "webp"
        default: nil
        }
    }
}

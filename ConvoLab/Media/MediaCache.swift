import CryptoKit
import Foundation
import SwiftData

@Observable
final class MediaCache {
    private let api: APIClient
    private let context: ModelContext
    private let rootURL: URL

    private(set) var activeDownloads = 0
    @ObservationIgnored private var inFlightDownloads: [String: Task<URL, Error>] = [:]

    init(api: APIClient, context: ModelContext) {
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
    }

    func localURL(for remoteURL: URL, cacheKey explicitCacheKey: String? = nil) -> URL? {
        let cacheKey = explicitCacheKey ?? Self.stableCacheKey(for: remoteURL)
        var descriptor = FetchDescriptor<CachedMediaRecord>(
            predicate: #Predicate { $0.remoteURL == cacheKey }
        )
        descriptor.fetchLimit = 1
        guard let record = try? context.fetch(descriptor).first else {
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
        let cacheKey = explicitCacheKey ?? Self.stableCacheKey(for: remoteURL)
        if let existing = localURL(for: remoteURL, cacheKey: cacheKey) {
            return existing
        }

        if let existingDownload = inFlightDownloads[cacheKey] {
            return try await existingDownload.value
        }

        let download = Task { @MainActor [self] in
            try await performDownload(
                remoteURL,
                category: category,
                cacheKey: cacheKey
            )
        }
        inFlightDownloads[cacheKey] = download
        defer { inFlightDownloads[cacheKey] = nil }
        return try await download.value
    }

    private func performDownload(
        _ remoteURL: URL,
        category: String,
        cacheKey: String
    ) async throws -> URL {
        activeDownloads += 1
        defer { activeDownloads -= 1 }

        let (temporaryURL, response) = try await api.download(remoteURL)
        let mimeExtension = response.mimeType.flatMap(Self.fileExtension(for:))
        let remoteExtension = remoteURL.pathExtension.isEmpty ? nil : remoteURL.pathExtension
        let fileExtension = mimeExtension ?? remoteExtension ?? "bin"
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let filename = "\(digest).\(fileExtension)"
        let destination = rootURL.appending(path: filename)

        if FileManager.default.fileExists(atPath: destination.path) {
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
        context.insert(CachedMediaRecord(
            remoteURL: cacheKey,
            relativePath: filename,
            byteCount: bytes,
            category: category
        ))
        try context.save()
        return destination
    }

    func prepare(urls: [URL], category: String) async {
        for url in Array(Set(urls)) {
            do {
                _ = try await download(url, category: category)
            } catch {
                // Preparation is best effort. The owning screen can still stream while online.
            }
        }
    }

    func cachedKeys(for remoteURLs: [URL]) -> Set<String> {
        let desiredKeys = Set(remoteURLs.map(Self.stableCacheKey(for:)))
        guard !desiredKeys.isEmpty else { return [] }

        let records = (try? context.fetch(FetchDescriptor<CachedMediaRecord>())) ?? []
        var availableKeys: Set<String> = []
        var removedMissingRecord = false

        for record in records where desiredKeys.contains(record.remoteURL) {
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

    var totalByteCount: Int64 {
        let records = (try? context.fetch(FetchDescriptor<CachedMediaRecord>())) ?? []
        return records.reduce(0) { $0 + $1.byteCount }
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

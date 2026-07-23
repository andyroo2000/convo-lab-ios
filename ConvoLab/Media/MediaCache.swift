import CryptoKit
import Foundation
import SwiftData

@Observable
final class MediaCache {
    private let api: APIClient
    private let context: ModelContext
    private let rootURL: URL

    private(set) var activeDownloads = 0

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

    func localURL(for remoteURL: URL) -> URL? {
        let remote = remoteURL.absoluteString
        var descriptor = FetchDescriptor<CachedMediaRecord>(
            predicate: #Predicate { $0.remoteURL == remote }
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
        return url
    }

    @discardableResult
    func download(_ remoteURL: URL, category: String) async throws -> URL {
        if let existing = localURL(for: remoteURL) {
            return existing
        }

        activeDownloads += 1
        defer { activeDownloads -= 1 }

        let (temporaryURL, response) = try await api.download(remoteURL)
        let mimeExtension = response.mimeType.flatMap(Self.fileExtension(for:))
        let remoteExtension = remoteURL.pathExtension.isEmpty ? nil : remoteURL.pathExtension
        let fileExtension = mimeExtension ?? remoteExtension ?? "bin"
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let filename = "\(digest).\(fileExtension)"
        let destination = rootURL.appending(path: filename)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        context.insert(CachedMediaRecord(
            remoteURL: remoteURL.absoluteString,
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

    var totalByteCount: Int64 {
        let records = (try? context.fetch(FetchDescriptor<CachedMediaRecord>())) ?? []
        return records.reduce(0) { $0 + $1.byteCount }
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


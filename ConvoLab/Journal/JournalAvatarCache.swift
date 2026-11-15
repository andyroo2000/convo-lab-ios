import Foundation
import UIKit

@MainActor
final class JournalAvatarCache {
    static let shared = JournalAvatarCache()
    private final class CachedImage {
        let image: UIImage
        let savedAt: Date
        init(_ image: UIImage, savedAt: Date) { self.image = image; self.savedAt = savedAt }
    }

    private let images = NSCache<NSURL, CachedImage>()
    private var requests: [URL: Task<UIImage?, Never>] = [:]
    private let disk: JournalAvatarDiskCache
    private let session: URLSession
    private let baseURL: URL
    private let lifetime: TimeInterval

    init(session: URLSession = .shared, directory: URL? = nil,
         baseURL: URL = AppConfiguration.load().apiBaseURL, lifetime: TimeInterval = 3_600) {
        self.session = session
        self.baseURL = baseURL
        self.lifetime = lifetime
        let root = directory ?? URL.cachesDirectory.appendingPathComponent("JournalAvatars", isDirectory: true)
        disk = JournalAvatarDiskCache(directory: root)
        images.countLimit = 64
        images.totalCostLimit = 32 * 1_024 * 1_024
    }

    func resolve(_ value: String?) -> URL? {
        guard let value, !value.isEmpty,
              let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    func cachedImage(for url: URL) -> UIImage? { images.object(forKey: url as NSURL)?.image }

    func storedImage(for url: URL) async -> UIImage? {
        if let image = cachedImage(for: url) { return image }
        guard let entry = await disk.read(url), let image = UIImage(data: entry.data) else { return nil }
        // A download may have finished while the disk actor was reading.
        if let current = cachedImage(for: url) { return current }
        remember(image, for: url, savedAt: entry.savedAt)
        return image
    }

    func preload(_ values: [String?]) {
        for url in Set(values.compactMap(resolve)) {
            Task { _ = await image(for: url) }
        }
    }

    /// Disk reads and network requests are shared by preloading and every visible portrait.
    func image(for url: URL) async -> UIImage? {
        if let cached = images.object(forKey: url as NSURL), isFresh(cached.savedAt) { return cached.image }
        if let request = requests[url] { return await request.value }
        let request = Task { await load(url) }
        requests[url] = request
        let result = await request.value
        requests[url] = nil
        return result
    }

    private func load(_ url: URL) async -> UIImage? {
        if let entry = await disk.read(url), let image = UIImage(data: entry.data) {
            remember(image, for: url, savedAt: entry.savedAt)
            if isFresh(entry.savedAt) { return image }
        }
        return await download(url) ?? cachedImage(for: url)
    }

    private func download(_ url: URL) async -> UIImage? {
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 20)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  data.count <= 4 * 1_024 * 1_024, let image = UIImage(data: data) else { return nil }
            let savedAt = Date()
            remember(image, for: url, savedAt: savedAt)
            await disk.write(.init(data: data, savedAt: savedAt), for: url)
            return image
        } catch { return nil }
    }

    private func remember(_ image: UIImage, for url: URL, savedAt: Date) {
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        images.setObject(CachedImage(image, savedAt: savedAt), forKey: url as NSURL, cost: cost)
    }

    private func isFresh(_ date: Date) -> Bool {
        let age = Date().timeIntervalSince(date)
        return age >= 0 && age < lifetime
    }
}

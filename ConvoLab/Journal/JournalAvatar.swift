import SwiftUI

struct JournalAvatar: View {
    let url: String?
    @State private var loaded: UIImage?
    @State private var loadedURL: URL?
    private let cache = JournalAvatarCache.shared

    var body: some View {
        let resolved = cache.resolve(url)
        let image = resolved.flatMap { cache.cachedImage(for: $0) } ?? (loadedURL == resolved ? loaded : nil)
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.task(id: resolved) {
            guard let resolved else { loaded = nil; loadedURL = nil; return }
            let stored = await cache.storedImage(for: resolved)
            guard !Task.isCancelled else { return }
            loadedURL = resolved
            loaded = stored
            let result = await cache.image(for: resolved)
            guard !Task.isCancelled else { return }
            loadedURL = resolved
            loaded = result
        }
    }
}

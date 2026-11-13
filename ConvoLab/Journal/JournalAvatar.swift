import SwiftUI

struct JournalAvatar: View {
    let url: String?
    private static let baseURL = AppConfiguration.load().apiBaseURL
    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0, relativeTo: Self.baseURL)?.absoluteURL }) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary) }
        }
    }
}

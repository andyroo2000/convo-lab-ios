import SwiftUI

struct JournalAvatar: View {
    let url: String?
    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0, relativeTo: AppConfiguration.load().apiBaseURL)?.absoluteURL }) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary) }
        }
    }
}

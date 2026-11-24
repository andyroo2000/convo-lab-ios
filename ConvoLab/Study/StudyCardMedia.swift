import SwiftUI

struct StudyCardAudioButton: View {
    let remoteURL: URL
    let trackID: String
    let label: String
    let autoplay: Bool
    let store: StudyStore
    let player: StudyAudioPlayer

    @State private var localURL: URL?
    @State private var didAttemptLoad = false

    var body: some View {
        let playing = player.isCurrent(trackID) && player.isPlaying
        Button {
            guard let localURL else { return }
            player.play(url: localURL, trackID: trackID)
        } label: {
            StudySpeakerIcon(playing: playing)
        }
        .buttonStyle(StudyWashiAudioButtonStyle(playing: playing))
        .accessibilityLabel(label)
        .accessibilityValue(playing ? "Playing" : "Not playing")
        .disabled(localURL == nil || player.isBlockedByLongFormAudio)
        .accessibilityHint(
            player.isBlockedByLongFormAudio
                ? "Pause Daily Audio before playing a study card."
                : didAttemptLoad && localURL == nil
                ? "Audio is not available offline."
                : "Plays downloaded study audio."
        )
        .task(id: "\(trackID)|autoplay:\(autoplay)") {
            didAttemptLoad = false
            localURL = nil
            let resolvedURL = await store.playableMediaURL(for: remoteURL)
            guard !Task.isCancelled else { return }
            localURL = resolvedURL
            didAttemptLoad = true
            if autoplay, let resolvedURL {
                player.play(url: resolvedURL, trackID: trackID)
            }
        }
    }
}

struct StudyCardImage: View {
    let remoteURL: URL
    let accessibilityLabel: String
    let store: StudyStore

    @State private var image: UIImage?
    @State private var didAttemptLoad = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel(accessibilityLabel)
            } else if !didAttemptLoad {
                ProgressView()
                    .accessibilityLabel("Loading study image")
            } else {
                Label("Image unavailable offline", systemImage: "photo.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: remoteURL) {
            didAttemptLoad = false
            image = nil
            let localURL = await store.playableMediaURL(for: remoteURL)
            guard !Task.isCancelled else { return }
            image = localURL.flatMap {
                UIImage(contentsOfFile: $0.path)
            }
            didAttemptLoad = true
        }
    }
}

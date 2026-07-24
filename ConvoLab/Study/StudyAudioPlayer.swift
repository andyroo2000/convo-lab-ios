import AVFAudio
import AVFoundation
import Foundation

@Observable
final class StudyAudioPlayer {
    private let player = AVPlayer()
    private var currentTrackID: String?
    @ObservationIgnored private var completionObserver: NSObjectProtocol?

    private(set) var isPlaying = false

    init() {
        completionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let completedItem = notification.object as? AVPlayerItem else { return }
            let completedItemID = ObjectIdentifier(completedItem)
            MainActor.assumeIsolated {
                guard
                    let self,
                    let currentItem = self.player.currentItem,
                    ObjectIdentifier(currentItem) == completedItemID
                else {
                    return
                }
                self.isPlaying = false
            }
        }
    }

    isolated deinit {
        if let completionObserver {
            NotificationCenter.default.removeObserver(completionObserver)
        }
    }

    func play(url: URL, trackID: String) {
        activateAudioSession()
        currentTrackID = trackID
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: .zero)
        player.play()
        isPlaying = true
    }

    func stop() {
        player.pause()
        isPlaying = false
    }

    func isCurrent(_ trackID: String) -> Bool {
        currentTrackID == trackID
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // AVPlayer will remain stopped if the system cannot activate playback.
        }
    }
}

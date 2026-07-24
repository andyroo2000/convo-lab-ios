import AVFAudio
import AVFoundation
import Foundation

@Observable
final class StudyAudioPlayer {
    private let player = AVPlayer()
    private let isLongFormAudioPlaying: @MainActor () -> Bool
    private var currentTrackID: String?
    private var ownsAudioSession = false
    @ObservationIgnored private var completionObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?

    private(set) var isPlaying = false
    var isBlockedByLongFormAudio: Bool { isLongFormAudioPlaying() }

    init(isLongFormAudioPlaying: @escaping @MainActor () -> Bool) {
        self.isLongFormAudioPlaying = isLongFormAudioPlaying
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
                self.deactivateAudioSessionIfOwned()
            }
        }
        configureAudioNotifications()
    }

    isolated deinit {
        if let completionObserver {
            NotificationCenter.default.removeObserver(completionObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    func play(url: URL, trackID: String) {
        guard !isBlockedByLongFormAudio else { return }
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
        deactivateAudioSessionIfOwned()
    }

    func isCurrent(_ trackID: String) -> Bool {
        currentTrackID == trackID
    }

    private func activateAudioSession() {
        guard !isLongFormAudioPlaying() else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio
            )
            try AVAudioSession.sharedInstance().setActive(true)
            ownsAudioSession = true
        } catch {
            // AVPlayer will remain stopped if the system cannot activate playback.
        }
    }

    private func deactivateAudioSessionIfOwned() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        guard !isLongFormAudioPlaying() else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func configureAudioNotifications() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeValue = (notification.userInfo?[
                AVAudioSessionInterruptionTypeKey
            ] as? NSNumber)?.uintValue
            MainActor.assumeIsolated {
                guard
                    let self,
                    let typeValue,
                    AVAudioSession.InterruptionType(rawValue: typeValue) == .began
                else {
                    return
                }
                self.player.pause()
                self.isPlaying = false
                self.deactivateAudioSessionIfOwned()
            }
        }
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reasonValue = (notification.userInfo?[
                AVAudioSessionRouteChangeReasonKey
            ] as? NSNumber)?.uintValue
            MainActor.assumeIsolated {
                guard
                    let self,
                    let reasonValue,
                    AVAudioSession.RouteChangeReason(rawValue: reasonValue)
                        == .oldDeviceUnavailable
                else {
                    return
                }
                self.player.pause()
                self.isPlaying = false
                self.deactivateAudioSessionIfOwned()
            }
        }
    }
}

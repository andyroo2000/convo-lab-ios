import AVFAudio
import AVFoundation
import Foundation

private nonisolated final class StudyAudioNotificationToken: @unchecked Sendable {
    private let observer: NSObjectProtocol

    init(_ observer: NSObjectProtocol) {
        self.observer = observer
    }

    deinit {
        NotificationCenter.default.removeObserver(observer)
    }
}

@Observable
final class StudyAudioPlayer {
    @ObservationIgnored private var player: AVPlayer?
    private let isLongFormAudioPlaying: @MainActor () -> Bool
    private var currentTrackID: String?
    private var ownsAudioSession = false
    @ObservationIgnored private var completionObserver: StudyAudioNotificationToken?
    @ObservationIgnored private var interruptionObserver: StudyAudioNotificationToken?
    @ObservationIgnored private var routeChangeObserver: StudyAudioNotificationToken?

    private(set) var isPlaying = false
    var isBlockedByLongFormAudio: Bool { isLongFormAudioPlaying() }

    static func allowsPlayback(whileLongFormAudioIsPlaying isPlaying: Bool) -> Bool {
        !isPlaying
    }

    init(isLongFormAudioPlaying: @escaping @MainActor () -> Bool) {
        self.isLongFormAudioPlaying = isLongFormAudioPlaying
    }

    private func preparePlayerIfNeeded() -> AVPlayer {
        if let player {
            return player
        }
        let player = AVPlayer()
        self.player = player
        completionObserver = StudyAudioNotificationToken(
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let completedItem = notification.object as? AVPlayerItem else { return }
                let completedItemID = ObjectIdentifier(completedItem)
                MainActor.assumeIsolated {
                    guard
                        let self,
                        let currentItem = self.player?.currentItem,
                        ObjectIdentifier(currentItem) == completedItemID
                    else {
                        return
                    }
                    self.isPlaying = false
                    self.deactivateAudioSessionIfOwned()
                }
            }
        )
        configureAudioNotifications()
        return player
    }

    func play(url: URL, trackID: String) {
        guard Self.allowsPlayback(
            whileLongFormAudioIsPlaying: isBlockedByLongFormAudio
        ) else {
            return
        }
        activateAudioSession()
        let player = preparePlayerIfNeeded()
        currentTrackID = trackID
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: .zero)
        player.play()
        isPlaying = true
    }

    func stop() {
        player?.pause()
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
        interruptionObserver = StudyAudioNotificationToken(
            center.addObserver(
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
                    self.player?.pause()
                    self.isPlaying = false
                    self.deactivateAudioSessionIfOwned()
                }
            }
        )
        routeChangeObserver = StudyAudioNotificationToken(
            center.addObserver(
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
                    self.player?.pause()
                    self.isPlaying = false
                    self.deactivateAudioSessionIfOwned()
                }
            }
        )
    }
}

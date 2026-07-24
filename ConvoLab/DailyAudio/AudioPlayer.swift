import AVFAudio
import AVFoundation
import Foundation
import MediaPlayer

@Observable
final class AudioPlayer {
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var currentTrackID: String?
    private var currentTitle = ""
    private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var completionObserver: NSObjectProtocol?

    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0

    init() {
        configureRemoteCommands()
        configureAudioNotifications()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                self.duration = self.player.currentItem?.duration.seconds.isFinite == true
                    ? self.player.currentItem?.duration.seconds ?? 0
                    : 0
                self.persistPosition()
                self.updateNowPlaying()
            }
        }
    }

    isolated deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        let center = NotificationCenter.default
        if let interruptionObserver {
            center.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            center.removeObserver(routeChangeObserver)
        }
        if let completionObserver {
            center.removeObserver(completionObserver)
        }
    }

    func play(
        url: URL,
        trackID: String,
        title: String,
        resumesFromSavedPosition: Bool = true
    ) {
        activateAudioSession()
        if currentTrackID != trackID {
            currentTrackID = trackID
            currentTitle = title
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            let saved = resumesFromSavedPosition
                ? UserDefaults.standard.double(forKey: positionKey(trackID))
                : 0
            if saved > 0 {
                player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
            }
        } else if !resumesFromSavedPosition {
            player.seek(to: .zero)
            elapsed = 0
        }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func toggle() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            resumePlayback()
        }
        updateNowPlaying()
    }

    func stop() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
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
            // The player will surface a playback failure if activation remains unavailable.
        }
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resumePlayback()
            }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.player.pause()
                self?.isPlaying = false
                self?.updateNowPlaying()
            }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor [weak self] in
                self?.seek(to: position)
            }
            return .success
        }
    }

    private func configureAudioNotifications() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonValue: reasonValue)
            }
        }
        completionObserver = center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let completedItem = notification.object as? AVPlayerItem else {
                return
            }
            let completedItemID = ObjectIdentifier(completedItem)
            MainActor.assumeIsolated {
                guard
                    let self,
                    let currentItem = self.player.currentItem,
                    ObjectIdentifier(currentItem) == completedItemID
                else {
                    return
                }
                self.handlePlaybackCompletion()
            }
        }
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            player.pause()
            isPlaying = false
            updateNowPlaying()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                player.play()
                isPlaying = true
            }
            wasPlayingBeforeInterruption = false
            updateNowPlaying()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard
            let reasonValue,
            AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable
        else {
            return
        }
        // Do not unexpectedly continue spoken audio through the speaker when headphones
        // or another output route disappear.
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    private func handlePlaybackCompletion() {
        isPlaying = false
        elapsed = duration
        if let currentTrackID {
            UserDefaults.standard.removeObject(forKey: positionKey(currentTrackID))
        }
        updateNowPlaying()
    }

    private func resumePlayback() {
        activateAudioSession()
        if duration > 0, elapsed >= duration - 0.25 {
            player.seek(to: .zero)
            elapsed = 0
        }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    private func persistPosition() {
        guard let currentTrackID else { return }
        UserDefaults.standard.set(elapsed, forKey: positionKey(currentTrackID))
    }

    private func positionKey(_ trackID: String) -> String {
        "daily-audio.position.\(trackID)"
    }

    private func updateNowPlaying() {
        guard currentTrackID != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyAlbumTitle: "ConvoLab Daily Audio",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0,
        ]
    }
}

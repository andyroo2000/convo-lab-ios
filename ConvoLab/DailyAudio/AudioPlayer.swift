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

    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0

    init() {
        configureAudioSession()
        configureRemoteCommands()
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

    func play(url: URL, trackID: String, title: String) {
        if currentTrackID != trackID {
            currentTrackID = trackID
            currentTitle = title
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            let saved = UserDefaults.standard.double(forKey: positionKey(trackID))
            if saved > 0 {
                player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
            }
        }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func toggle() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func isCurrent(_ trackID: String) -> Bool {
        currentTrackID == trackID
    }

    private func configureAudioSession() {
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
            self?.player.play()
            self?.isPlaying = true
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause()
            self?.isPlaying = false
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard
                let self,
                let event = event as? MPChangePlaybackPositionCommandEvent
            else {
                return .commandFailed
            }
            seek(to: event.positionTime)
            return .success
        }
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

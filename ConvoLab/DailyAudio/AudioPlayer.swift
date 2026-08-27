import AVFAudio
import AVFoundation
import Foundation
import MediaPlayer

struct DailyAudioPlaybackIdentity: Hashable, Sendable {
    let trackID: String
    let revisionMilliseconds: Int64

    init(track: DailyAudioTrack) {
        trackID = track.id
        revisionMilliseconds = Int64(
            (track.updatedAt.timeIntervalSince1970 * 1_000).rounded()
        )
    }
}

final class AudioPlaybackDiagnostics {
    private let diagnostics: NativeDiagnostics
    private var interval: NativeDiagnosticInterval?
    private var interruptionWasActive = false

    init(diagnostics: NativeDiagnostics) {
        self.diagnostics = diagnostics
    }

    func start() {
        guard interval == nil else { return }
        interval = diagnostics.begin(.backgroundPlayback)
        diagnostics.record(.backgroundPlayback, reason: .playbackStarted)
    }

    func stop(outcome: NativeDiagnosticOutcome) {
        guard let interval else { return }
        self.interval = nil
        diagnostics.record(.backgroundPlayback, reason: .playbackStopped)
        diagnostics.end(interval, outcome: outcome)
    }

    func interruptionBegan() {
        guard interval != nil else { return }
        interruptionWasActive = true
        diagnostics.record(.backgroundPlayback, reason: .interruptionBegan)
        stop(outcome: .cancelled)
    }

    func interruptionEnded(willResume: Bool) {
        guard interruptionWasActive else { return }
        interruptionWasActive = false
        diagnostics.record(.backgroundPlayback, reason: .interruptionEnded)
        if willResume { start() }
    }

    func outputRouteWasLost() {
        guard interval != nil else { return }
        diagnostics.record(.backgroundPlayback, reason: .outputRouteLost)
        stop(outcome: .cancelled)
    }

    deinit {
        if let interval {
            diagnostics.end(interval, outcome: .cancelled)
        }
    }
}

@Observable
final class AudioPlayer {
    private enum PlaybackBackend {
        case avPlayer(AVPlayer)
#if DEBUG
        case deterministicUITest
#endif
    }

    private let backend: PlaybackBackend
    private var player: AVPlayer {
        switch backend {
        case let .avPlayer(player):
            player
#if DEBUG
        case .deterministicUITest:
            preconditionFailure("The deterministic UI-test backend has no AVPlayer")
#endif
        }
    }
    private var usesDeterministicBackend: Bool {
#if DEBUG
        if case .deterministicUITest = backend { return true }
#endif
        return false
    }
    private let playbackDiagnostics: AudioPlaybackDiagnostics
    private var timeObserver: Any?
    private var currentTrackIdentity: DailyAudioPlaybackIdentity?
    private var currentTitle = ""
    private var wasPlayingBeforeInterruption = false
    private var onWillStartPlayback: @MainActor () -> Void = {}
    private var onPlaybackStateChanged: @MainActor (Bool, String) -> Void = { _, _ in }
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var completionObserver: NSObjectProtocol?

    private(set) var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            onPlaybackStateChanged(isPlaying, currentTitle)
        }
    }
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var isRepeating = false

    static func replacesPlayingTrack(
        isPlaying: Bool,
        currentTrackIdentity: DailyAudioPlaybackIdentity?,
        newTrackIdentity: DailyAudioPlaybackIdentity
    ) -> Bool {
        isPlaying && currentTrackIdentity != newTrackIdentity
    }

    static func toggledRepeatState(_ current: Bool) -> Bool {
        !current
    }

    init(diagnostics: NativeDiagnostics = .shared) {
        let player = AVPlayer()
        backend = .avPlayer(player)
        playbackDiagnostics = AudioPlaybackDiagnostics(diagnostics: diagnostics)
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

#if DEBUG
    /// Test-only audio boundary. It exercises the production player state machine
    /// without registering remote commands, touching AVAudioSession, or decoding media.
    init(
        deterministicUITestBackend: Void,
        diagnostics: NativeDiagnostics = .shared
    ) {
        backend = .deterministicUITest
        playbackDiagnostics = AudioPlaybackDiagnostics(diagnostics: diagnostics)
    }
#endif

    isolated deinit {
        if let timeObserver, case let .avPlayer(player) = backend {
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

    func play(url: URL, track: DailyAudioTrack) {
        let identity = DailyAudioPlaybackIdentity(track: track)
        onWillStartPlayback()
        if usesDeterministicBackend {
            if currentTrackIdentity != identity {
                currentTrackIdentity = identity
                currentTitle = track.title
                elapsed = 0
            }
            duration = 60
            isPlaying = true
            return
        }
        activateAudioSession()
        let replacedPlayingTrack = Self.replacesPlayingTrack(
            isPlaying: isPlaying,
            currentTrackIdentity: currentTrackIdentity,
            newTrackIdentity: identity
        )
        if currentTrackIdentity != identity {
            currentTrackIdentity = identity
            currentTitle = track.title
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            let saved = UserDefaults.standard.double(forKey: positionKey(identity))
            if saved > 0 {
                player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
            }
        }
        isPlaying = true
        beginPlaybackDiagnosticsIfNeeded()
        if replacedPlayingTrack {
            onPlaybackStateChanged(true, currentTitle)
        }
        player.play()
        updateNowPlaying()
    }

    func toggle() {
        if usesDeterministicBackend {
            isPlaying.toggle()
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
            endPlaybackDiagnostics(outcome: .succeeded)
        } else {
            resumePlayback()
        }
        updateNowPlaying()
    }

    func stop() {
        if usesDeterministicBackend {
            isPlaying = false
            currentTrackIdentity = nil
            currentTitle = ""
            elapsed = 0
            duration = 0
            return
        }
        player.pause()
        persistPosition()
        isPlaying = false
        player.replaceCurrentItem(with: nil)
        currentTrackIdentity = nil
        currentTitle = ""
        elapsed = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        endPlaybackDiagnostics(outcome: .succeeded)
    }

    func seek(to seconds: Double) {
        if usesDeterministicBackend {
            elapsed = min(max(seconds, 0), duration)
            return
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func isCurrent(_ track: DailyAudioTrack) -> Bool {
        currentTrackIdentity == DailyAudioPlaybackIdentity(track: track)
    }

    func toggleRepeat() {
        isRepeating = Self.toggledRepeatState(isRepeating)
    }

    func setPlaybackStartHandler(_ handler: @escaping @MainActor () -> Void) {
        onWillStartPlayback = handler
    }

    func setPlaybackStateHandler(
        _ handler: @escaping @MainActor (Bool, String) -> Void
    ) {
        onPlaybackStateChanged = handler
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
                self?.endPlaybackDiagnostics(outcome: .succeeded)
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
            if wasPlayingBeforeInterruption {
                playbackDiagnostics.interruptionBegan()
            }
            player.pause()
            isPlaying = false
            updateNowPlaying()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            if wasPlayingBeforeInterruption {
                playbackDiagnostics.interruptionEnded(
                    willResume: options.contains(.shouldResume)
                )
            }
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
        let wasPlaying = isPlaying
        player.pause()
        isPlaying = false
        if wasPlaying {
            playbackDiagnostics.outputRouteWasLost()
        }
        updateNowPlaying()
    }

    private func handlePlaybackCompletion() {
        if isRepeating {
            player.seek(to: .zero)
            elapsed = 0
            isPlaying = true
            player.play()
            updateNowPlaying()
            return
        }
        isPlaying = false
        elapsed = duration
        if let currentTrackIdentity {
            UserDefaults.standard.removeObject(forKey: positionKey(currentTrackIdentity))
        }
        updateNowPlaying()
        endPlaybackDiagnostics(outcome: .succeeded)
    }

    private func resumePlayback() {
        isPlaying = true
        onWillStartPlayback()
        activateAudioSession()
        if duration > 0, elapsed >= duration - 0.25 {
            player.seek(to: .zero)
            elapsed = 0
        }
        player.play()
        beginPlaybackDiagnosticsIfNeeded()
        updateNowPlaying()
    }

    private func beginPlaybackDiagnosticsIfNeeded() {
        playbackDiagnostics.start()
    }

    private func endPlaybackDiagnostics(outcome: NativeDiagnosticOutcome) {
        playbackDiagnostics.stop(outcome: outcome)
    }

    private func persistPosition() {
        guard let currentTrackIdentity else { return }
        UserDefaults.standard.set(elapsed, forKey: positionKey(currentTrackIdentity))
    }

    private func positionKey(_ identity: DailyAudioPlaybackIdentity) -> String {
        "daily-audio.position.\(identity.trackID).\(identity.revisionMilliseconds)"
    }

    private func updateNowPlaying() {
        guard currentTrackIdentity != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyAlbumTitle: "ConvoLab Daily Audio",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0,
        ]
    }
}

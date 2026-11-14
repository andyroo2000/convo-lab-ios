import AVFoundation
import Foundation

@MainActor
@Observable
final class JournalAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private static weak var activePlayer: JournalAudioPlayer?
    private var player: AVAudioPlayer?
    private var generation = 0
    private var seeking = false
    private var progressTask: Task<Void, Never>?
    private(set) var sentences: [JournalSentenceTiming] = []
    private(set) var position: Double = 0
    private(set) var engaged = false
    private(set) var isPlaying = false
    private(set) var preparing = false
    var errorMessage: String?
    nonisolated deinit {}

    var duration: Double { player?.duration ?? 0 }

    func toggle(entryID: String, analysis: JournalAnalysis, voice: String, service: JournalService) async {
        await toggleTimed {
            let body = JournalAudioPayload(analysisId: analysis.id, voiceId: voice, expectedReplyRevision: analysis.replyRevision ?? 0)
            return try await service.timedAudio(entryID: entryID, body: body)
        }
    }

    func toggleTimed(load: () async throws -> JournalTimedRecording) async {
        await toggleRecording { expectedGeneration in
            let recording = try await load()
            try Task.checkCancellation()
            guard Self.activePlayer === self, self.generation == expectedGeneration else { throw CancellationError() }
            self.sentences = recording.sentences
            return try recording.audioData()
        }
    }

    func toggle(load: () async throws -> Data) async {
        await toggleRecording { _ in try await load() }
    }

    private func toggleRecording(load: (Int) async throws -> Data) async {
        if let player { togglePlayback(player); return }
        guard !preparing else { return }
        Self.activePlayer?.stop()
        Self.activePlayer = self
        preparing = true
        errorMessage = nil
        generation += 1
        let request = generation
        defer { if request == generation { preparing = false } }
        do {
            let data = try await load(request)
            guard request == generation else { return }
            try Task.checkCancellation()
            let audio = try AVAudioPlayer(data: data)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            audio.delegate = self
            player = audio
            guard audio.play() else { throw APIClientError.invalidResponse }
            isPlaying = true
            engaged = true
            trackProgress()
        } catch {
            if request == generation { stop(); errorMessage = "Audio could not be prepared. Try again." }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == finished else { return }
            isPlaying = false
            engaged = false
            position = duration
            progressTask?.cancel()
            releaseSession()
        }
    }

    private func togglePlayback(_ audio: AVAudioPlayer) {
        if audio.isPlaying { audio.pause(); isPlaying = false; progressTask?.cancel(); releaseSession(); return }
        Self.activePlayer?.stopOther(than: self)
        Self.activePlayer = self
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { errorMessage = "Audio could not be resumed. Try again."; return }
        if position >= audio.duration { audio.currentTime = 0; position = 0 }
        guard audio.play() else {
            releaseSession()
            errorMessage = "Audio could not be resumed. Try again."
            return
        }
        errorMessage = nil
        isPlaying = true
        engaged = true
        trackProgress()
    }

    func seek(_ value: Double) {
        guard value.isFinite, player != nil else { return }
        position = min(max(value, 0), duration)
        player?.currentTime = position
        engaged = true
    }

    func setSeeking(_ value: Bool) { seeking = value }

    func moveSentence(_ direction: Int) {
        if let time = JournalSentenceTimeline.adjacent(sentences, at: position, direction: direction) { seek(time) }
    }

    private func stopOther(than active: JournalAudioPlayer) { if self !== active { stop() } }

    private func trackProgress() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                if self?.seeking == false { self?.position = self?.player?.currentTime ?? 0 }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
    private func releaseSession() {
        guard Self.activePlayer === self else { return }
        Self.activePlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stop() {
        releaseSession()
        generation += 1
        progressTask?.cancel()
        progressTask = nil
        seeking = false
        sentences = []
        position = 0
        engaged = false
        player?.stop()
        player = nil
        preparing = false
        isPlaying = false
    }
}

import AVFoundation
import Foundation

@MainActor
@Observable
final class JournalAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private static weak var activePlayer: JournalAudioPlayer?
    private var player: AVAudioPlayer?
    private var generation = 0
    private var seekRevision = 0
    private(set) var isPlaying = false
    private(set) var preparing = false
    var errorMessage: String?
    nonisolated deinit {}

    var duration: Double { player?.duration ?? 0 }
    var position: Double { _ = seekRevision; return player?.currentTime ?? 0 }

    func toggle(entryID: String, analysis: JournalAnalysis, voice: String, service: JournalService) async {
        await toggle {
            let body = JournalAudioPayload(analysisId: analysis.id, voiceId: voice, expectedReplyRevision: analysis.replyRevision ?? 0)
            return try await service.audio(entryID: entryID, body: body)
        }
    }

    func toggle(load: () async throws -> Data) async {
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
            let data = try await load()
            guard request == generation else { return }
            try Task.checkCancellation()
            let audio = try AVAudioPlayer(data: data)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            audio.delegate = self
            player = audio
            guard audio.play() else { throw APIClientError.invalidResponse }
            isPlaying = true
        } catch {
            if request == generation { stop(); errorMessage = "Audio could not be prepared. Try again." }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == finished else { return }
            stop()
        }
    }

    private func togglePlayback(_ audio: AVAudioPlayer) {
        if audio.isPlaying { audio.pause(); isPlaying = false; return }
        if audio.currentTime >= audio.duration { audio.currentTime = 0 }
        isPlaying = audio.play()
    }

    func seek(_ value: Double) { player?.currentTime = min(max(value, 0), duration); seekRevision += 1 }
    func stop() {
        if Self.activePlayer === self { Self.activePlayer = nil }
        generation += 1
        if player != nil {
            player?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        player = nil
        preparing = false
        isPlaying = false
    }
}

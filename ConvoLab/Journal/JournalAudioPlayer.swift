import AVFoundation
import Foundation

@MainActor
@Observable
final class JournalAudioPlayer {
    private var player: AVAudioPlayer?
    private var generation = 0
    private(set) var preparing = false
    var errorMessage: String?
    nonisolated deinit {}

    var duration: Double { player?.duration ?? 0 }
    var position: Double { player?.currentTime ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }

    func toggle(entryID: String, analysis: JournalAnalysis, voice: String, service: JournalService) async {
        if let player { togglePlayback(player); return }
        guard !preparing else { return }
        preparing = true
        errorMessage = nil
        generation += 1
        let request = generation
        defer { if request == generation { preparing = false } }
        do {
            let body = JournalAudioPayload(analysisId: analysis.id, voiceId: voice, expectedReplyRevision: analysis.replyRevision ?? 0)
            let data = try await service.audio(entryID: entryID, body: body)
            guard request == generation else { return }
            try Task.checkCancellation()
            let audio = try AVAudioPlayer(data: data)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player = audio
            guard audio.play() else { throw APIClientError.invalidResponse }
        } catch {
            if request == generation { errorMessage = "Audio could not be prepared. Try again."; player = nil }
        }
    }

    private func togglePlayback(_ audio: AVAudioPlayer) {
        if audio.isPlaying { audio.pause(); return }
        if audio.currentTime >= audio.duration { audio.currentTime = 0 }
        audio.play()
    }

    func seek(_ value: Double) { player?.currentTime = min(max(value, 0), duration) }
    func stop() {
        generation += 1
        if player != nil {
            player?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        player = nil
        preparing = false
    }
}

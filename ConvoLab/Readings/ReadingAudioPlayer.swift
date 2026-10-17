import AVFoundation
import Foundation

@Observable
final class ReadingAudioPlayer {
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var preparing = false
    var errorMessage: String?

    func play(reading: ReadingDetail, sentence: Int, store: ReadingStore, beforeAudio: () -> Void) {
        stop()
        beforeAudio()
        generation += 1
        let requestGeneration = generation
        preparing = true
        task = Task {
            defer { if generation == requestGeneration { preparing = false } }
            do {
                try store.checkSession()
                let data = try await store.resource("/api/convolab/readings/\(reading.id)/sentences/\(sentence)/audio",
                                                    key: "audio:\(reading.id):\(reading.revision):\(reading.voiceId):\(sentence)", method: "POST")
                try store.checkSession()
                guard requestGeneration == generation else { return }
                let player = try AVAudioPlayer(data: data)
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                self.player = player
                guard player.play() else { throw APIClientError.invalidResponse }
            } catch is CancellationError {
                return
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        preparing = false
    }
}

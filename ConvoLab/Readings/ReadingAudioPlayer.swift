import AVFoundation
import Foundation

@Observable
final class ReadingAudioPlayer: NSObject, AVAudioPlayerDelegate {
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
                let player: AVAudioPlayer
                do { player = try AVAudioPlayer(data: data) }
                catch {
                    store.invalidateResource(key: "audio:\(reading.id):\(reading.revision):\(reading.voiceId):\(sentence)")
                    throw error
                }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                player.delegate = self
                self.player = player
                guard player.play() else { throw APIClientError.invalidResponse }
            } catch is CancellationError {
                return
            } catch {
                guard requestGeneration == generation else { return }
                stop()
                errorMessage = error.localizedDescription
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == finished else { return }
            stop()
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        if player != nil {
            player?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        player = nil
        preparing = false
    }
}

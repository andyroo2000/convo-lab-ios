import SwiftUI
import AVFoundation

struct JournalQuestionAudioView: View {
    let model: JournalTutorModel
    let question: JournalTutorQuestion
    @State private var player = JournalAudioPlayer()
    @Environment(\.journalBeforeAudio) private var beforeAudio
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if question.audio?.status == "ready" {
                TimelineView(.animation(minimumInterval: 0.25, paused: !player.isPlaying)) { _ in
                    HStack(spacing: 10) {
                        Button {
                            if !player.isPlaying { beforeAudio() }
                            Task { await player.toggle { try await model.service.questionAudio(entryID: model.entryID, questionID: question.id) } }
                        } label: {
                            if player.preparing { ProgressView() }
                            else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(minWidth: 44, minHeight: 44) }
                        }.disabled(player.preparing).accessibilityLabel(player.isPlaying ? "Pause question" : "Play question")
                        Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
                            .disabled(player.duration == 0).accessibilityLabel("Question audio position")
                        Text(clock(player.position)).font(.caption.monospacedDigit())
                    }
                }
            } else if question.audio?.waiting == true {
                ProgressView("Preparing question audio…").font(.footnote)
            }
            if let error = player.errorMessage ?? question.audio?.error {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("Retry question audio") { Task { player.stop(); player.errorMessage = nil; await model.load() } }.font(.footnote).disabled(model.isBusy)
            }
        }
        .onChange(of: scenePhase) { if scenePhase != .active { player.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: DispatchQueue.main)) { _ in player.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: DispatchQueue.main)) { event in
            if event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { player.stop() }
        }
        .onDisappear { player.stop() }
    }
    private func clock(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

import SwiftUI
import AVFoundation

struct JournalQuestionAudioView: View {
    let model: JournalTutorModel
    let question: JournalTutorQuestion
    let player: JournalAudioPlayer
    @Environment(\.journalBeforeAudio) private var beforeAudio
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JournalMinimalAudioControls(player: player, label: "question") {
                if !player.isPlaying { beforeAudio() }
                Task { await player.toggleTimed { try await model.service.timedQuestionAudio(entryID: model.entryID, questionID: question.id) } }
            }
            if let error = player.errorMessage {
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
}

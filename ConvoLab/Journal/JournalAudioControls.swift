import SwiftUI
import AVFoundation

extension EnvironmentValues {
    @Entry var journalBeforeAudio: () -> Void = {}
}

struct JournalAudioControls: View {
    let entryID: String
    let analysis: JournalAnalysis
    let service: JournalService
    let player: JournalAudioPlayer
    let voice: JournalVoiceSelection
    @Binding var choosingVoice: Bool
    @Binding var version: JournalVersion
    var edit: (() -> Void)?
    @Environment(\.journalBeforeAudio) private var beforeAudio
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JournalCompactAudioHeader(player: player, voice: voice) {
                if !player.isPlaying { beforeAudio() }
                Task { await player.toggle(entryID: entryID, analysis: analysis, voice: voice.selected, service: service) }
            }
            if let message = voice.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Retry loading voices") { Task { await loadVoices() } }.font(.footnote)
            }
            if let error = player.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .outsideDismissibleSheet(isPresented: $choosingVoice) { ScrollView { JournalVoicePicker(voice: voice, choosing: $choosingVoice).padding() }.presentationDetents([.medium, .large]).presentationBackground(.white).environment(\.colorScheme, .light) }
        .onChange(of: voice.isLoading) { if voice.isLoading { choosingVoice = false } }
        .onChange(of: voice.errorMessage) { if voice.errorMessage != nil { choosingVoice = false } }
        .onChange(of: voice.voices.count) { if voice.voices.isEmpty { choosingVoice = false } }
        .onChange(of: voice.selected) { player.stop() }
        .onChange(of: analysis.id) { player.stop() }
        .onChange(of: analysis.replyRevision) { player.stop() }
        .onChange(of: scenePhase) { if scenePhase != .active { player.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: DispatchQueue.main)) { _ in player.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: DispatchQueue.main)) { event in
            if event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                player.stop()
            }
        }
        .onDisappear { player.stop() }
    }

    private func loadVoices() async {
        await voice.load(entryID: entryID, analysis: analysis, service: service)
    }
}

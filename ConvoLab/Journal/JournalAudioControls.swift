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
    @State private var voice = JournalVoiceSelection()
    @State private var choosingVoice = false
    @Environment(\.journalBeforeAudio) private var beforeAudio
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if choosingVoice { JournalVoicePicker(voice: voice, choosing: $choosingVoice) }
            JournalMinimalAudioControls(player: player, label: "corrected version", disabled: !voice.isReady) {
                if !player.isPlaying { beforeAudio() }
                Task { await player.toggle(entryID: entryID, analysis: analysis, voice: voice.selected, service: service) }
            }
            HStack {
                Spacer()
                Button { choosingVoice.toggle() } label: { Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44) }
                    .disabled(voice.isLoading || voice.errorMessage != nil)
                    .accessibilityLabel("Narration voice").accessibilityIdentifier("JournalVoicePicker")
                    .accessibilityHint(choosingVoice ? "Voice choices expanded" : "Opens voice choices")
                    .accessibilityValue(voice.voices.first(where: { $0.id == voice.selected })?.name ?? "Not selected")
            }
            if voice.isLoading { Text("Loading saved voice…").font(.footnote).foregroundStyle(.secondary) }
            if let message = voice.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Retry loading voices") { Task { await loadVoices() } }.font(.footnote)
            }
            if let error = player.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .task(id: "\(entryID):\(analysis.id):\(analysis.replyRevision ?? 0)") { await loadVoices() }
        .onChange(of: voice.isLoading) { if voice.isLoading { choosingVoice = false } }
        .onChange(of: voice.errorMessage) { if voice.errorMessage != nil { choosingVoice = false } }
        .onChange(of: voice.voices.count) { if voice.voices.isEmpty { choosingVoice = false } }
        .onChange(of: voice.selected) { player.stop() }
        .onChange(of: analysis.replyRevision) { player.stop() }
        .onChange(of: scenePhase) { if scenePhase != .active { player.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: DispatchQueue.main)) { _ in player.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: DispatchQueue.main)) { event in
            if event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                player.stop()
            }
        }
        .onDisappear { player.stop(); voice.cancel() }
    }

    private func loadVoices() async {
        await voice.load(entryID: entryID, analysis: analysis, service: service)
    }
}

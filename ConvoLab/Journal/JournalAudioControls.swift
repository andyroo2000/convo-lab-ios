import SwiftUI
import AVFoundation

extension EnvironmentValues {
    @Entry var journalBeforeAudio: () -> Void = {}
}

struct JournalAudioControls: View {
    let entryID: String
    let analysis: JournalAnalysis
    let service: JournalService
    @State private var player = JournalAudioPlayer()
    @State private var voices: [JournalVoice] = []
    @State private var voice = ""
    @State private var voiceError = false
    @Environment(\.journalBeforeAudio) private var beforeAudio
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                HStack(spacing: 12) {
                    Button {
                        if !player.isPlaying { beforeAudio() }
                        Task { await player.toggle(entryID: entryID, analysis: analysis, voice: voice, service: service) }
                    } label: {
                        if player.preparing { ProgressView() }
                        else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                    }.disabled(voice.isEmpty || player.preparing).accessibilityLabel(player.isPlaying ? "Pause corrected version" : "Play corrected version")
                    Text(clock(player.position)).font(.caption.monospacedDigit())
                    Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
                        .disabled(player.duration == 0).accessibilityLabel("Audio position")
                    Picker("Voice", selection: $voice) {
                        ForEach(voices) { Text($0.name).tag($0.id) }
                    }.labelsHidden().pickerStyle(.menu).accessibilityLabel("Narration voice").accessibilityIdentifier("JournalVoicePicker")
                }
            }
            if voiceError { Button("Retry loading voices") { Task { await loadVoices() } }.font(.footnote) }
            if let error = player.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(12).background(.white.opacity(0.8), in: .rect(cornerRadius: 12))
        .task { await loadVoices() }
        .onChange(of: voice) { player.stop() }
        .onChange(of: analysis.replyRevision) { player.stop() }
        .onChange(of: scenePhase) { if scenePhase != .active { player.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in player.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { event in
            if event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                player.stop()
            }
        }
        .onDisappear { player.stop() }
    }

    private func loadVoices() async {
        do {
            voices = try await service.voices()
            voice = voices.first(where: { $0.name == "Ren" })?.id ?? voices.first?.id ?? ""
            voiceError = voices.isEmpty
        } catch { voiceError = true }
    }
    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

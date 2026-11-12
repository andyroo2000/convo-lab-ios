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
    @State private var voice = JournalVoiceSelection()
    @Environment(\.journalBeforeAudio) private var beforeAudio
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.animation(minimumInterval: 0.25, paused: !player.isPlaying)) { _ in
                HStack(spacing: 12) {
                    Button {
                        if !player.isPlaying { beforeAudio() }
                        Task { await player.toggle(entryID: entryID, analysis: analysis, voice: voice.selected, service: service) }
                    } label: {
                        if player.preparing { ProgressView() }
                        else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                    }.disabled(!voice.isReady || player.preparing).accessibilityLabel(player.isPlaying ? "Pause corrected version" : "Play corrected version")
                    Text(clock(player.position)).font(.caption.monospacedDigit())
                    Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
                        .disabled(player.duration == 0).accessibilityLabel("Audio position").accessibilityValue(clock(player.position))
                    Menu {
                        Picker("Narration voice", selection: $voice.selected) {
                        if voice.selected.isEmpty { Text("Select voice").tag("") }
                        ForEach(voice.voices) { Text($0.name).tag($0.id) }
                        }
                    } label: { Image(systemName: "person.wave.2").frame(minWidth: 44, minHeight: 44) }
                        .disabled(voice.isLoading || voice.errorMessage != nil)
                        .accessibilityLabel("Narration voice").accessibilityIdentifier("JournalVoicePicker")
                }
            }
            if voice.isLoading { Text("Loading saved voice…").font(.footnote).foregroundStyle(.secondary) }
            if let message = voice.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Retry loading voices") { Task { await loadVoices() } }.font(.footnote)
            }
            if let error = player.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(12).background(.white.opacity(0.8), in: .rect(cornerRadius: 12))
        .task(id: "\(entryID):\(analysis.id):\(analysis.replyRevision ?? 0)") { await loadVoices() }
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
    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

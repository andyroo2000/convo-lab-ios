import SwiftUI

struct DailyAudioPlayerView: View {
    let track: DailyAudioTrack
    let store: DailyAudioStore
    let player: AudioPlayer

    @State private var detailedTrack: DailyAudioTrack?
    @State private var isPreparing = false
    @State private var couldNotLoad = false
    @State private var showReadings = false

    private var latestTrack: DailyAudioTrack {
        DailyAudioTrack.latest(matching: track, in: store.practices)
    }

    private var activeTrack: DailyAudioTrack {
        detailedTrack ?? latestTrack
    }

    private var playbackDuration: Double {
        if player.isCurrent(activeTrack), player.duration > 0 {
            return player.duration
        }
        return activeTrack.approxDurationSeconds ?? 0
    }

    private var currentUnit: DailyAudioScriptUnit? {
        guard player.isCurrent(activeTrack) else { return nil }
        return DailyAudioTranscript.currentSpokenUnit(
            in: activeTrack,
            elapsedSeconds: player.elapsed,
            durationSeconds: playbackDuration
        )
    }

    @State private var showText = false
    @State private var playRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: togglePlayback) {
                    Label(isPreparing ? "Loading…" : (playing ? "Pause" : "Play"), systemImage: playing ? "pause.fill" : "play.fill")
                        .font(StudyTimePaper.type(18)).padding(.horizontal, 14).frame(minHeight: 44)
                        .foregroundStyle(.white).background(DrillPaper.accent, in: Capsule())
                }.buttonStyle(.plain).disabled(isPreparing)
                VStack(spacing: 0) {
                    Slider(value: Binding(get: { min(elapsed, max(playbackDuration, 1)) },
                        set: { player.seek(to: $0) }), in: 0...max(playbackDuration, 1))
                        .accessibilityLabel("Seek in drill").tint(DrillPaper.accent)
                        .disabled(!player.isCurrent(activeTrack) || playbackDuration <= 0)
                    HStack { Text(formatTime(elapsed)); Spacer(); Text(formatTime(playbackDuration)) }
                        .font(.caption.monospacedDigit())
                }
            }
            if couldNotLoad {
                Text("Audio could not play. Tap Play to retry.").font(.footnote)
            }
            HStack {
                Spacer()
                Button { showText.toggle() } label: {
                    Label(showText ? "Hide text" : "Show text", systemImage: showText ? "chevron.up" : "chevron.down")
                        .font(StudyTimePaper.type(17)).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
            if showText { transcript }
        }
        .task(id: DailyAudioPlaybackIdentity(track: latestTrack)) {
            let requested = latestTrack
            let detail = await store.detailedTrack(for: requested)
            guard !Task.isCancelled else { return }
            detailedTrack = detail
        }
        .task(id: playRequest) {
            guard playRequest > 0 else { return }
            await startPlayback()
        }
    }

    private var elapsed: Double { player.isCurrent(activeTrack) ? player.elapsed : 0 }
    private var playing: Bool { player.isCurrent(activeTrack) && player.isPlaying }

    @ViewBuilder private var transcript: some View {
        Divider()
        let unit = currentUnit ?? (elapsed == 0 ? activeTrack.scriptUnitsJson?.first { $0.type == "L2" } : nil)
        if let unit, let text = unit.text {
            StudyRubyText(showReadings ? unit.reading ?? text : text, knownKanji: [], pointSize: 22,
                weight: .medium, color: UIColor(DrillPaper.ink), alignment: .natural)
            if let translation = unit.translation { Text(translation).font(StudyTimePaper.type(18)) }
            if unit.reading != nil { Toggle("Furigana", isOn: $showReadings).font(.footnote).fixedSize() }
        } else {
            Text(activeTrack.scriptUnitsJson?.isEmpty == false ? "Listening…" : "No transcript available.").font(.footnote)
        }
    }

    private func startPlayback() async {
        let requested = activeTrack
        isPreparing = true
        couldNotLoad = false
        defer { isPreparing = false }
        let url = await store.playableURL(for: requested)
        guard !Task.isCancelled, DailyAudioPlaybackIdentity(track: requested) == DailyAudioPlaybackIdentity(track: latestTrack) else { return }
        if let url { player.play(url: url, track: requested) }
        else { couldNotLoad = true }
    }

    private func togglePlayback() {
        if player.isCurrent(activeTrack) { player.toggle() }
        else { playRequest += 1 }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

}

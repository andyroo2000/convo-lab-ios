import SwiftUI

struct DailyAudioPlayerView: View {
    let track: DailyAudioTrack
    let store: DailyAudioStore
    let player: AudioPlayer

    @State private var detailedTrack: DailyAudioTrack?
    @State private var resolvedURL: URL?
    @State private var isPreparing = true
    @State private var couldNotLoad = false
    @State private var showReadings = false
    @State private var showTranslation = false

    private var activeTrack: DailyAudioTrack {
        detailedTrack ?? track
    }

    private var playbackDuration: Double {
        if player.isCurrent(track.id), player.duration > 0 {
            return player.duration
        }
        return activeTrack.approxDurationSeconds ?? 0
    }

    private var currentUnit: DailyAudioScriptUnit? {
        guard player.isCurrent(track.id) else { return nil }
        return DailyAudioTranscript.currentSpokenUnit(
            in: activeTrack,
            elapsedSeconds: player.elapsed,
            durationSeconds: playbackDuration
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    ConvoLabTheme.cyan.opacity(0.22),
                    ConvoLabTheme.cream,
                    ConvoLabTheme.coral.opacity(0.08),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                trackHeader
                spokenTextDisplay
                    .frame(maxHeight: .infinity)
                playbackControls
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ConvoLabTheme.cream.opacity(0.94), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: track.id) {
            await prepareForPlayback()
        }
    }

    private var trackHeader: some View {
        VStack(spacing: 6) {
            Text(track.mode.uppercased())
                .font(.caption.bold())
                .tracking(2.4)
                .foregroundStyle(ConvoLabTheme.coral)
            Text(track.title)
                .font(.title2.bold())
                .foregroundStyle(ConvoLabTheme.navy)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.top, 22)
    }

    private var spokenTextDisplay: some View {
        VStack(spacing: 18) {
            if isPreparing {
                ProgressView("Preparing audio…")
                    .tint(ConvoLabTheme.navy)
            } else if couldNotLoad {
                ContentUnavailableView(
                    "Audio Unavailable",
                    systemImage: "waveform.slash",
                    description: Text("Connect to the internet and try this drill again.")
                )
            } else {
                currentText
                transcriptOptions
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .background(.white.opacity(0.58), in: .rect(cornerRadius: 32))
        .overlay {
            RoundedRectangle(cornerRadius: 32)
                .stroke(ConvoLabTheme.navy.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: ConvoLabTheme.navy.opacity(0.08), radius: 24, y: 12)
        .padding(.vertical, 28)
    }

    @ViewBuilder
    private var currentText: some View {
        if let unit = currentUnit, let text = unit.text {
            VStack(spacing: 18) {
                StudyRubyText(
                    showReadings ? unit.reading ?? text : text,
                    knownKanji: [],
                    pointSize: 34,
                    weight: .semibold,
                    color: UIColor(ConvoLabTheme.navy),
                    alignment: .center
                )
                .id("\(unit.text ?? "")-\(showReadings)")
                .transition(.opacity)

                Text(showTranslation ? unit.translation ?? " " : " ")
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 24)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 42, weight: .medium))
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                Text(player.isPlaying ? "Listening…" : "Ready when you are")
                    .font(.title3.bold())
            }
            .foregroundStyle(ConvoLabTheme.navy.opacity(0.48))
        }
    }

    private var transcriptOptions: some View {
        HStack(spacing: 12) {
            optionButton(
                title: "Furigana",
                systemImage: "character.book.closed",
                isOn: showReadings
            ) {
                showReadings.toggle()
            }
            optionButton(
                title: "Translation",
                systemImage: "text.bubble",
                isOn: showTranslation
            ) {
                showTranslation.toggle()
            }
        }
        .opacity(activeTrack.timingData?.isEmpty == false ? 1 : 0)
        .accessibilityHidden(activeTrack.timingData?.isEmpty != false)
    }

    private func optionButton(
        title: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(isOn ? Color.white : ConvoLabTheme.navy)
                .background(
                    isOn ? ConvoLabTheme.navy : ConvoLabTheme.navy.opacity(0.08),
                    in: .capsule
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var playbackControls: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: {
                            min(
                                player.isCurrent(track.id) ? player.elapsed : 0,
                                max(playbackDuration, 1)
                            )
                        },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(playbackDuration, 1)
                )
                .tint(ConvoLabTheme.navy)
                .disabled(!player.isCurrent(track.id) || playbackDuration <= 0)

                HStack {
                    Text(formatTime(player.isCurrent(track.id) ? player.elapsed : 0))
                    Spacer()
                    Text("-\(formatTime(remainingTime))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 42) {
                seekButton(offset: -15, systemImage: "gobackward.15")

                Button {
                    togglePlayback()
                } label: {
                    ZStack {
                        Circle()
                            .fill(ConvoLabTheme.navy)
                            .frame(width: 76, height: 76)
                        Image(systemName: player.isCurrent(track.id) && player.isPlaying
                            ? "pause.fill"
                            : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: player.isCurrent(track.id) && player.isPlaying ? 0 : 2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPreparing || couldNotLoad)
                .accessibilityLabel(
                    player.isCurrent(track.id) && player.isPlaying ? "Pause" : "Play"
                )

                seekButton(offset: 15, systemImage: "goforward.15")
            }
        }
    }

    private var remainingTime: Double {
        max(playbackDuration - (player.isCurrent(track.id) ? player.elapsed : 0), 0)
    }

    private func seekButton(offset: Double, systemImage: String) -> some View {
        Button {
            let target = min(max(player.elapsed + offset, 0), playbackDuration)
            player.seek(to: target)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(ConvoLabTheme.navy)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .disabled(!player.isCurrent(track.id) || playbackDuration <= 0)
        .accessibilityLabel(offset < 0 ? "Back 15 Seconds" : "Forward 15 Seconds")
    }

    private func prepareForPlayback() async {
        isPreparing = true
        couldNotLoad = false
        let detailed = await store.detailedTrack(for: track) ?? track
        detailedTrack = detailed
        guard let url = await store.playableURL(for: detailed) else {
            isPreparing = false
            couldNotLoad = true
            return
        }
        resolvedURL = url
        isPreparing = false
        if !player.isCurrent(track.id) {
            player.play(url: url, trackID: track.id, title: track.title)
        }
    }

    private func togglePlayback() {
        if player.isCurrent(track.id) {
            player.toggle()
        } else if let resolvedURL {
            player.play(url: resolvedURL, trackID: track.id, title: track.title)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

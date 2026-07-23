import SwiftUI

struct DailyAudioView: View {
    let store: DailyAudioStore
    let player: AudioPlayer

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    createPanel

                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .padding()
                    }

                    if store.practices.isEmpty, !store.isLoading {
                        ContentUnavailableView(
                            "No Daily Audio yet",
                            systemImage: "waveform",
                            description: Text("Creation requires a connection. Finished tracks can be downloaded and played offline.")
                        )
                        .padding(.vertical, 40)
                    }

                    ForEach(store.practices) { practice in
                        practiceCard(practice)
                    }
                }
                .padding()
            }
            .paperBackground()
            .navigationTitle("Daily Audio")
            .refreshable {
                await store.refresh()
            }
        }
    }

    private var createPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STUDY AUDIO")
                .font(.caption2.bold())
                .tracking(2)
                .foregroundStyle(ConvoLabTheme.coral)
            Text("Practice beyond the screen.")
                .font(.title2.bold())
                .foregroundStyle(ConvoLabTheme.navy)
            Text("Generate a 30-minute practice from the cards you’re learning today.")
                .foregroundStyle(.secondary)
            Button {
                Task { await store.create() }
            } label: {
                Label(
                    store.isLoading ? "Working…" : "Generate Today’s Audio",
                    systemImage: "waveform.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(ConvoLabTheme.navy)
            .disabled(store.isLoading)
        }
        .padding()
        .background(ConvoLabTheme.cyan.opacity(0.16), in: .rect(cornerRadius: 20))
    }

    private func practiceCard(_ practice: DailyAudioPractice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text(practice.practiceDate)
                        .font(.headline)
                    Text(practice.status.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if practice.status == "ready" {
                    Button {
                        Task { await store.download(practice) }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel("Download for Offline")
                } else if practice.status == "generating" {
                    ProgressView()
                }
            }

            ForEach(practice.tracks.sorted { $0.sortOrder < $1.sortOrder }) { track in
                trackRow(track)
            }
        }
        .padding()
        .background(.white.opacity(0.76), in: .rect(cornerRadius: 20))
    }

    private func trackRow(_ track: DailyAudioTrack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(track.title)
                        .font(.headline)
                    Text(track.mode.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if let url = store.playableURL(for: track), track.status == "ready" {
                    Button {
                        if player.isCurrent(track.id) {
                            player.toggle()
                        } else {
                            player.play(url: url, trackID: track.id, title: track.title)
                        }
                    } label: {
                        Image(systemName: player.isCurrent(track.id) && player.isPlaying
                            ? "pause.circle.fill"
                            : "play.circle.fill")
                            .font(.title)
                    }
                }
            }

            if player.isCurrent(track.id), player.duration > 0 {
                Slider(
                    value: Binding(
                        get: { player.elapsed },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...player.duration
                )
            }
        }
        .padding(.vertical, 4)
    }
}


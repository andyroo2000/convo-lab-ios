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

                    if store.hasMore {
                        ProgressView("Loading earlier days…")
                            .padding()
                            .task(id: store.nextCursor) {
                                await store.loadMore()
                            }
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
        Group {
            if track.audioUrl != nil, track.status == "ready" {
                NavigationLink {
                    DailyAudioPlayerView(track: track, store: store, player: player)
                } label: {
                    trackRowLabel(track, isPlayable: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the audio player")
            } else {
                trackRowLabel(track, isPlayable: false)
            }
        }
        .padding(.vertical, 4)
    }

    private func trackRowLabel(
        _ track: DailyAudioTrack,
        isPlayable: Bool
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(ConvoLabTheme.cyan.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: player.isCurrent(track.id) && player.isPlaying
                    ? "waveform"
                    : "play.fill")
                    .foregroundStyle(ConvoLabTheme.navy)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.headline)
                    .foregroundStyle(ConvoLabTheme.navy)
                Text(track.mode.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if isPlayable {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            } else if track.status == "generating" || track.status == "draft" {
                ProgressView()
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

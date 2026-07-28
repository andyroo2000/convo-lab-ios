import SwiftUI

struct DailyAudioView: View {
    let store: DailyAudioStore
    let player: AudioPlayer
    @State private var selectedPracticeID: String?
    @State private var confirmingRegeneration = false

    private var selectedPractice: DailyAudioPractice? {
        guard let selectedPracticeID else { return store.practices.first }
        return store.practices.first { $0.id == selectedPracticeID }
            ?? store.practices.first
    }

    private var todayPractice: DailyAudioPractice? {
        store.practices.first { $0.practiceDate == Self.todayPracticeDate }
    }

    private var todayIsGenerating: Bool {
        todayPractice?.status == "generating"
    }

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

                    if let practice = selectedPractice {
                        practiceCard(practice)
                    }

                    if store.practices.count > 1 {
                        Text(dayNavigationHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .paperBackground()
            .navigationTitle("Daily Audio")
            .refreshable {
                await store.refresh()
            }
            .onChange(of: store.practices.map(\.id), initial: true) { _, ids in
                if selectedPracticeID == nil || !ids.contains(selectedPracticeID ?? "") {
                    selectedPracticeID = ids.first
                }
            }
            .confirmationDialog(
                "Regenerate today’s audio?",
                isPresented: $confirmingRegeneration,
                titleVisibility: .visible
            ) {
                Button("Regenerate Audio", role: .destructive) {
                    Task { await store.create() }
                }
                Button("Keep Existing Audio", role: .cancel) {}
            } message: {
                Text("This will overwrite today’s existing audio drills. Previously downloaded versions may need to be downloaded again.")
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
            Text("Generate audio drills based on words and grammar structures you are currently working on.")
                .foregroundStyle(.secondary)
            Button {
                if todayPractice == nil {
                    Task { await store.create() }
                } else {
                    confirmingRegeneration = true
                }
            } label: {
                Label(
                    store.isLoading || todayIsGenerating
                        ? "Working…"
                        : todayPractice == nil
                            ? "Generate Today’s Audio"
                            : "Regenerate Today’s Audio",
                    systemImage: "waveform.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(ConvoLabTheme.navy)
            .disabled(store.isLoading || todayIsGenerating)
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
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width > 50 {
                        showEarlierPractice()
                    } else if value.translation.width < -50 {
                        showLaterPractice()
                    }
                }
        )
        .accessibilityAction(named: Text("Show Earlier Day")) {
            showEarlierPractice()
        }
        .accessibilityAction(named: Text("Show Later Day")) {
            showLaterPractice()
        }
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
                Text(track.formattedDuration)
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

    private var dayNavigationHint: String {
        guard let selectedPractice,
              let index = store.practices.firstIndex(where: { $0.id == selectedPractice.id })
        else {
            return ""
        }
        return index > 0
            ? "Swipe right for earlier days or left for later days."
            : "Swipe right for earlier days."
    }

    private func showEarlierPractice() {
        guard let selectedPractice,
              let index = store.practices.firstIndex(where: { $0.id == selectedPractice.id })
        else {
            return
        }
        if store.practices.indices.contains(index + 1) {
            selectedPracticeID = store.practices[index + 1].id
        } else if store.hasMore {
            Task {
                await store.loadMore()
                guard let currentIndex = store.practices.firstIndex(where: {
                    $0.id == selectedPractice.id
                }), store.practices.indices.contains(currentIndex + 1)
                else {
                    return
                }
                selectedPracticeID = store.practices[currentIndex + 1].id
            }
        }
    }

    private func showLaterPractice() {
        guard let selectedPractice,
              let index = store.practices.firstIndex(where: { $0.id == selectedPractice.id }),
              index > 0
        else {
            return
        }
        selectedPracticeID = store.practices[index - 1].id
    }

    private static var todayPracticeDate: String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}

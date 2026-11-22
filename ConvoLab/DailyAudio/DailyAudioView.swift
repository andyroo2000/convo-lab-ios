import SwiftUI

enum DrillPaper {
    static let surface = Color(red: 0.91, green: 0.94, blue: 0.94)
    static let ink = Color(red: 0.15, green: 0.28, blue: 0.32)
    static let accent = Color(red: 0.22, green: 0.40, blue: 0.46)
    static let rule = Color(red: 0.67, green: 0.77, blue: 0.79)
}

struct DailyAudioView: View {
    let store: DailyAudioStore
    let player: AudioPlayer
    let capabilities: StudyCapabilities.DailyAudio
    @State private var selectedID: String?
    @State private var creating = false
    private static let staleGenerationRetryInterval: TimeInterval = 90 * 60

    private var today: DailyAudioPractice? {
        store.practices.first { $0.practiceDate == Self.todayPracticeDate }
    }

    private var recordings: [DailyAudioPractice] {
        store.practices.filter { drill(in: $0) != nil }
    }

    private func drill(in practice: DailyAudioPractice) -> DailyAudioTrack? {
        practice.tracks.first { $0.mode == "drill" && $0.status == "ready" && $0.audioUrl != nil }
    }

    private var recording: (DailyAudioPractice, DailyAudioTrack)? {
        let choices = recordings
        guard let practice = choices.first(where: { $0.id == selectedID }) ?? choices.first,
              let track = drill(in: practice) else { return nil }
        return (practice, track)
    }

    @ViewBuilder private func dateLabel(_ practice: DailyAudioPractice) -> some View {
        let label = "\(Self.relativePracticeDate(practice.practiceDate)) · \(practice.targetDurationMinutes) min"
        Menu {
            if recordings.count > 1 {
                ForEach(recordings) { choice in
                    Button(choice.practiceDate + " · \(choice.targetDurationMinutes) min") {
                        if choice.id != practice.id { player.stop() }
                        selectedID = choice.id
                    }
                }
            }
            if let track = drill(in: practice), player.isCurrent(track) {
                Section("Playback") {
                    Button("Back 15 seconds") { player.seek(to: max(0, player.elapsed - 15)) }
                    Button("Forward 15 seconds") { player.seek(to: min(player.duration, player.elapsed + 15)) }
                    Button(player.isRepeating ? "Turn repeat off" : "Repeat drill") { player.toggleRepeat() }
                }
            }
            if !store.isDownloaded(practice) {
                Button("Download for offline listening") { Task { await store.download(practice) } }
                    .disabled(practice.tracks.contains(where: store.isDownloading))
            } else { Text("Available offline") }
            if store.hasMore { Button("Load earlier drills") { Task { await store.loadMore() } } }
        } label: { Label(label, systemImage: "chevron.down") }
        .accessibilityLabel("Recording date, " + label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                heading(at: context.date)
            }
            if let (_, track) = recording {
                DailyAudioPlayerView(track: track, store: store, player: player)
                    .id(DailyAudioPlaybackIdentity(track: track))
            } else if store.isLoading {
                ProgressView("Loading Daily Audio…")
            } else if today?.status != "generating" {
                Text("Create your first audio drill to start listening.").font(.subheadline)
            }
            if let error = store.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("Retry loading drills") { Task { _ = await store.refresh() } }
            }
            if today?.status == "error" {
                Text(today?.errorMessage ?? "The drill could not be generated. Try again.").font(.footnote)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(DrillPaper.ink).background(DrillPaper.surface, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(DrillPaper.rule) }
        .task {
            await store.refreshIfNeeded(maxAge: .seconds(60))
        }
        .onChange(of: store.practices.flatMap(\.tracks).map { DailyAudioPlaybackIdentity(track: $0) }) { _, _ in
            player.stopIfCurrentTrackWasSuperseded(by: store.practices.flatMap(\.tracks))
        }
        .outsideDismissibleSheet(isPresented: $creating) {
            NewDrillSheet(capabilities: capabilities, replacing: today?.status == "ready") { edition in
                if today?.status == "ready" { player.stop() }
                selectedID = nil
                creating = false
                Task { await store.create(edition: edition) }
            }
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder private func heading(at date: Date) -> some View {
        let active = today.map { $0.status == "generating" && !Self.canRetryGeneration($0,
            startRequestWasInterrupted: store.generationStartWasInterrupted, relativeTo: date) } ?? false
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily Audio").font(StudyTimePaper.type(27, .title2)).accessibilityAddTraits(.isHeader)
                if let (practice, _) = recording {
                    dateLabel(practice).font(.footnote)
                }
            }
            Spacer()
            Button { creating = true } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
                    .background(StudyTimePaper.paper, in: Circle()).overlay { Circle().stroke(DrillPaper.rule) }
            }.buttonStyle(.plain).accessibilityLabel("New audio drill").disabled(store.isLoading || active)
        }
        if active { Text("Preparing your audio drill…").font(.subheadline) }
        else if today?.status == "generating" { Text("Generation has stalled. Use New audio drill to retry.").font(.subheadline) }
    }

    static func relativePracticeDate(
        _ practiceDate: String,
        relativeTo referenceDate: Date = .now
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = .current
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd"

        guard let date = dateFormatter.date(from: practiceDate) else {
            return practiceDate
        }

        let calendar = Calendar.current
        let dayDifference = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: referenceDate),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if dayDifference == 0 {
            return "Today"
        }
        if dayDifference == -1 {
            return "Yesterday"
        }
        if dayDifference == 1 {
            return "Tomorrow"
        }
        if abs(dayDifference) > 7 { return date.formatted(date: .abbreviated, time: .omitted) }
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.dateTimeStyle = .named
        relativeFormatter.unitsStyle = .spellOut
        return relativeFormatter.localizedString(
            from: DateComponents(day: dayDifference)
        ).capitalized
    }

    static func canRetryGeneration(
        _ practice: DailyAudioPractice,
        startRequestWasInterrupted: Bool,
        relativeTo referenceDate: Date = .now
    ) -> Bool {
        if startRequestWasInterrupted {
            return true
        }
        guard practice.status == "generating" else { return false }
        // This conservative fallback exceeds the backend generation job timeout.
        return referenceDate.timeIntervalSince(practice.updatedAt)
            >= staleGenerationRetryInterval
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

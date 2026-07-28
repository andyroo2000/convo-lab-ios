import SwiftUI

struct DailyAudioView: View {
    private enum SwipeDirection {
        case earlier
        case later
    }

    let store: DailyAudioStore
    let player: AudioPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPracticeID: String?
    @State private var confirmingRegeneration = false
    @State private var dragOffset = CGFloat.zero
    @State private var cardWidth = CGFloat(360)
    @State private var isSettlingSwipe = false
    @State private var preparingTrackID: String?
    @State private var suppressTrackInteractions = false
    @State private var selectedPlayerTrack: DailyAudioTrack?

    private let dayCardSpacing = CGFloat(16)

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

    private var selectedPracticeIndex: Int? {
        guard let selectedPractice else { return nil }
        return store.practices.firstIndex { $0.id == selectedPractice.id }
    }

    private var earlierPractice: DailyAudioPractice? {
        guard
            let selectedPracticeIndex,
            store.practices.indices.contains(selectedPracticeIndex + 1)
        else {
            return nil
        }
        return store.practices[selectedPracticeIndex + 1]
    }

    private var laterPractice: DailyAudioPractice? {
        guard let selectedPracticeIndex, selectedPracticeIndex > 0 else {
            return nil
        }
        return store.practices[selectedPracticeIndex - 1]
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
                        swipeablePracticeStack(practice)
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
            .navigationDestination(
                isPresented: Binding(
                    get: { selectedPlayerTrack != nil },
                    set: { isPresented in
                        if !isPresented {
                            selectedPlayerTrack = nil
                        }
                    }
                )
            ) {
                if let selectedPlayerTrack {
                    DailyAudioPlayerView(
                        track: selectedPlayerTrack,
                        store: store,
                        player: player
                    )
                }
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

    private func swipeablePracticeStack(_ practice: DailyAudioPractice) -> some View {
        ZStack {
            if let earlierPractice {
                practiceCard(earlierPractice)
                    .offset(x: displayedDragOffset - cardTravelDistance)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if let laterPractice {
                practiceCard(laterPractice)
                    .offset(x: displayedDragOffset + cardTravelDistance)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            practiceCard(practice)
                .offset(x: displayedDragOffset)
                .zIndex(1)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        cardWidth = max(geometry.size.width, 1)
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        cardWidth = max(width, 1)
                    }
            }
        }
        .clipped()
        .simultaneousGesture(daySwipeGesture)
    }

    private func practiceCard(_ practice: DailyAudioPractice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text(Self.relativePracticeDate(practice.practiceDate))
                        .font(.headline)
                        .accessibilityLabel(
                            "\(Self.relativePracticeDate(practice.practiceDate)), \(practice.practiceDate)"
                        )
                    Text(practice.status.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if practice.status == "ready" {
                    Button {
                        guard !suppressTrackInteractions else { return }
                        Task { await store.download(practice) }
                    } label: {
                        practiceDownloadButton(practice)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.practiceDownloadProgress[practice.id] != nil)
                    .allowsHitTesting(!suppressTrackInteractions)
                    .accessibilityLabel(
                        store.isDownloaded(practice)
                            ? "Downloaded for Offline"
                            : store.practiceDownloadProgress[practice.id] != nil
                                ? "Downloading for Offline"
                                : "Download for Offline"
                    )
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
        .accessibilityAction(named: Text("Show Earlier Day")) {
            showEarlierPractice()
        }
        .accessibilityAction(named: Text("Show Later Day")) {
            showLaterPractice()
        }
    }

    @ViewBuilder
    private func practiceDownloadButton(_ practice: DailyAudioPractice) -> some View {
        if let progress = store.practiceDownloadProgress[practice.id] {
            ZStack {
                Circle()
                    .stroke(ConvoLabTheme.navy.opacity(0.16), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(progress, 0.04))
                    .stroke(
                        ConvoLabTheme.cyan,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 26, height: 26)
        } else if store.isDownloaded(practice) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
        }
    }

    private func trackRow(_ track: DailyAudioTrack) -> some View {
        HStack(spacing: 14) {
            if track.audioUrl != nil, track.status == "ready" {
                Button {
                    guard !suppressTrackInteractions else { return }
                    Task { await toggleTrackPlayback(track) }
                } label: {
                    ZStack {
                        Circle()
                            .fill(ConvoLabTheme.cyan.opacity(0.16))
                            .frame(width: 44, height: 44)
                        if preparingTrackID == track.id {
                            ProgressView()
                                .tint(ConvoLabTheme.navy)
                        } else {
                            Image(systemName: player.isCurrent(track.id) && player.isPlaying
                                ? "pause.fill"
                                : "play.fill")
                                .foregroundStyle(ConvoLabTheme.navy)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(preparingTrackID != nil)
                .allowsHitTesting(!suppressTrackInteractions)
                .accessibilityLabel(
                    player.isCurrent(track.id) && player.isPlaying
                        ? "Pause \(track.title)"
                        : "Play \(track.title)"
                )

                Button {
                    guard !suppressTrackInteractions else { return }
                    selectedPlayerTrack = track
                } label: {
                    trackNavigationLabel(track)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!suppressTrackInteractions)
                .accessibilityHint("Opens Now Playing")
            } else {
                unavailableTrackRow(track)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private func trackNavigationLabel(_ track: DailyAudioTrack) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.headline)
                    .foregroundStyle(ConvoLabTheme.navy)
                Text(track.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isDownloading(track) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Downloading")
            } else if store.isDownloaded(track) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Downloaded")
            }
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }

    private func unavailableTrackRow(_ track: DailyAudioTrack) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(ConvoLabTheme.cyan.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: "waveform.slash")
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

            if track.status == "generating" || track.status == "draft" {
                ProgressView()
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }

    private func toggleTrackPlayback(_ track: DailyAudioTrack) async {
        if player.isCurrent(track.id) {
            player.toggle()
            return
        }

        preparingTrackID = track.id
        defer {
            if preparingTrackID == track.id {
                preparingTrackID = nil
            }
        }
        let detailedTrack = await store.detailedTrack(for: track) ?? track
        guard
            preparingTrackID == track.id,
            let url = await store.playableURL(for: detailedTrack)
        else {
            return
        }
        player.play(url: url, trackID: track.id, title: track.title)
    }

    private var displayedDragOffset: CGFloat {
        if dragOffset > 0, earlierPractice == nil {
            return Self.rubberBand(dragOffset)
        }
        if dragOffset < 0, laterPractice == nil {
            return Self.rubberBand(dragOffset)
        }
        return dragOffset
    }

    private var cardTravelDistance: CGFloat {
        cardWidth + dayCardSpacing
    }

    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard
                    !isSettlingSwipe,
                    abs(value.translation.width) > abs(value.translation.height)
                else {
                    return
                }
                suppressTrackInteractions = true
                dragOffset = value.translation.width
            }
            .onEnded { value in
                guard !isSettlingSwipe else { return }
                restoreTrackInteractionsAfterSwipe()
                let horizontal = value.translation.width
                let predicted = value.predictedEndTranslation.width
                guard abs(horizontal) > abs(value.translation.height) else {
                    snapCardBack()
                    return
                }

                if max(horizontal, predicted) > 70 {
                    if let earlierPractice {
                        completeSwipe(to: earlierPractice.id, direction: .earlier)
                    } else if store.hasMore {
                        showEarlierPractice()
                    } else {
                        snapCardBack()
                    }
                } else if min(horizontal, predicted) < -70, let laterPractice {
                    completeSwipe(to: laterPractice.id, direction: .later)
                } else {
                    snapCardBack()
                }
            }
    }

    private func completeSwipe(to id: String, direction: SwipeDirection) {
        guard !isSettlingSwipe else { return }
        if player.isPlaying {
            player.toggle()
        }
        if reduceMotion {
            selectedPracticeID = id
            dragOffset = 0
            return
        }

        isSettlingSwipe = true
        let destination = direction == .earlier ? cardTravelDistance : -cardTravelDistance
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
            dragOffset = destination
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedPracticeID = id
                dragOffset = 0
                isSettlingSwipe = false
            }
        }
    }

    private func restoreTrackInteractionsAfterSwipe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            suppressTrackInteractions = false
        }
    }

    private func snapCardBack() {
        guard dragOffset != 0 else { return }
        if reduceMotion {
            dragOffset = 0
        } else {
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.72)) {
                dragOffset = 0
            }
        }
    }

    private func showEarlierPractice() {
        guard let selectedPractice,
              let index = store.practices.firstIndex(where: { $0.id == selectedPractice.id })
        else {
            return
        }
        if store.practices.indices.contains(index + 1) {
            completeSwipe(to: store.practices[index + 1].id, direction: .earlier)
        } else if store.hasMore {
            Task {
                await store.loadMore()
                guard let currentIndex = store.practices.firstIndex(where: {
                    $0.id == selectedPractice.id
                }), store.practices.indices.contains(currentIndex + 1)
                else {
                    return
                }
                completeSwipe(
                    to: store.practices[currentIndex + 1].id,
                    direction: .earlier
                )
            }
        } else {
            snapCardBack()
        }
    }

    private func showLaterPractice() {
        guard let selectedPractice,
              let index = store.practices.firstIndex(where: { $0.id == selectedPractice.id }),
              index > 0
        else {
            snapCardBack()
            return
        }
        completeSwipe(to: store.practices[index - 1].id, direction: .later)
    }

    private static func rubberBand(_ offset: CGFloat) -> CGFloat {
        let direction: CGFloat = offset < 0 ? -1 : 1
        return direction * min(pow(abs(offset), 0.72) * 1.8, 42)
    }

    private static func relativePracticeDate(_ practiceDate: String) -> String {
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
            from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.dateTimeStyle = .named
        relativeFormatter.unitsStyle = .spellOut
        return relativeFormatter.localizedString(
            from: DateComponents(day: dayDifference)
        ).capitalized
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

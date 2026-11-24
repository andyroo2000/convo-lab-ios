import SwiftUI
import UIKit

struct StudySessionView: View {
    enum Mode {
        case reviews
        case lessons
    }

    let store: StudyStore
    let player: StudyAudioPlayer
    let mode: Mode
    let timeStore: StudyTimeStore?
    let pileID: String?
    let lessonCohortID: String?
    let allowsLessonDismissal: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appModeDestination) private var appModeDestination

    @State private var showingAnswer = false
    @State private var selectedGrade: ReviewRating?
    @State private var promptFile: (recording: StudyPromptRecording, file: URL)?
    @State private var cardTimer = StudySessionCardTimer(startedAt: .now)
    @State private var submittingReviewCardIDs: Set<String> = []
    @State private var answerFile: (source: URL, local: URL?)?
    @State private var didAutoplayAnswerForCardID: String?
    @State private var editingCard: StudyCard?
    @State private var undoActions: [StudyUndoAction] = []
    @State private var isUndoing = false
    @State private var undoErrorMessage: String?
    @State private var answerRestoredByUndoCardID: String?
    @State private var lessonPreview = true
    @State private var lessonPreviewIndex = 0
    @State private var loadingLessons = false
    @State private var lessonLoadErrorMessage: String?
    @State private var submittingCardActionIDs: Set<String> = []
    @State private var cardPendingForget: StudyCard?
    @State private var cardPendingSetDue: StudyCard?
    @State private var cardActionErrorMessage: String?
    @State private var sessionReviewRecords: [StudySessionReviewRecord] = []
    @State private var sessionWasEnded = false
    @State private var wrapUpSummary: StudySessionWrapUpSummary
    @State private var practiceCards: [StudyCard]?
    @State private var practiceInitialCount = 0
    @State private var lessonPresentationID = UUID()

    init(
        store: StudyStore,
        player: StudyAudioPlayer,
        mode: Mode = .reviews,
        timeStore: StudyTimeStore? = nil,
        lessonCohortID: String? = nil,
        pileID: String? = nil,
        lessonPresentationID: UUID = UUID(),
        allowsLessonDismissal: Bool = false
    ) {
        self.store = store
        self.player = player
        self.mode = mode
        self.timeStore = timeStore
        self.lessonCohortID = lessonCohortID
        self.pileID = pileID
        self.allowsLessonDismissal = allowsLessonDismissal
        _lessonPresentationID = State(initialValue: lessonPresentationID)
        _lessonPreview = State(initialValue: mode == .lessons)
        _wrapUpSummary = State(initialValue: StudySessionWrapUpSummary.build(from: []))
    }

    private var card: StudyCard? {
        if let practiceCards {
            return practiceCards.first
        }
        return store.masteryAnimation?.card ?? store.cards.first
    }

    private var practiceMode: Bool { practiceCards != nil }

    private var practiceComplete: Bool { practiceCards?.isEmpty == true }

    @ToolbarContentBuilder
    private var lessonDismissToolbar: some ToolbarContent {
        if mode == .lessons, allowsLessonDismissal {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("StudyCloseLessonButton")
            }
        }
    }

    private var reviewSessionComplete: Bool {
        mode == .reviews
            && !practiceMode
            && !sessionReviewRecords.isEmpty
            && store.masteryAnimation == nil
            && store.cards.isEmpty
            && !store.sessionCounts.hasRemainingReviews
    }

    private var displayingCompletion: Bool {
        sessionWasEnded || reviewSessionComplete
    }

    private var sessionProgress: StudyCardProgress {
        if let practiceCards {
            return .batch(total: practiceInitialCount, remaining: practiceCards.count)
        }
        if mode == .lessons {
            return .batch(total: store.sessionInitialCardCount, remaining: store.cards.count)
        }
        let counts = store.sessionCounts
        let reviewed = Set(sessionReviewRecords.map { $0.cardBefore.reviewCardID.lowercased() })
        let queued = Set(store.cards.map { $0.reviewCardID.lowercased() })
        return .review(reviewed: reviewed, queued: queued, due: counts.reviewRemaining + counts.failedDue)
    }

    private var sessionContent: some View {
        VStack(spacing: 10) {
            activeSessionContent
        }
        .padding()
        .background { StudyWashiBackground() }
        .overlay(alignment: .top) { masteryFeedbackLane }
        .tint(StudyWashiStyle.ink)
        .overlay {
            InteractivePopGestureGuard(isDisabled: mode == .reviews) {
                endReviewSession()
            }
                .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private var activeSessionContent: some View {
        if mode == .lessons, lessonPreview {
            lessonPreviewContent
        } else if displayingCompletion, !practiceMode {
            wrapUpContent
        } else if practiceComplete {
            practiceCompleteContent
        } else if let card {
            StudyCardProgressView(progress: sessionProgress)
            if practiceMode {
                Text("Practice only · results won’t affect your review schedule")
                    .font(.caption.bold())
                    .foregroundStyle(StudyWashiStyle.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(ConvoLabTheme.cyan.opacity(0.16), in: .capsule)
                    .accessibilityIdentifier("StudyPracticeModeBanner")
            }
            let presentation = card.presentation
            StudyWashiCard(centered: true) {
                if showingAnswer {
                    StudySessionAnswer(face: presentation.back, store: store)
                } else {
                    promptFace(presentation.front)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Flashcard")

            if showingAnswer {
                gradeButtons(card: card)
            } else {
                Button("Show Answer") { revealAnswer(card) }
                    .buttonStyle(StudyRevealButtonStyle())
            }
        } else if mode == .lessons {
            ContentUnavailableView {
                Label("Lesson complete", systemImage: "checkmark.seal.fill")
            } description: {
                Text("This batch is now in FSRS learning.")
            } actions: {
                Button("Learn Another Batch") {
                    Task { await loadLessonBatch() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        } else if store.sessionCounts.hasRemainingReviews {
            ContentUnavailableView {
                Label("More cards are ready", systemImage: "rectangle.stack.badge.plus")
            } description: {
                Text("Load the next study batch to keep going.")
            } actions: {
                Button("Load Next Study Batch") {
                    Task { await store.loadNextReviewBatch() }
                }
                .buttonStyle(.borderedProminent)
                .tint(StudyWashiStyle.ink)
                .disabled(store.syncStatus == .syncing)
            }
        } else {
            ContentUnavailableView(
                "Session complete",
                systemImage: "checkmark.seal.fill",
                description: Text(offlineReviewCompletionMessage)
            )
        }
    }

    var body: some View {
        sessionViewWithLifecycle
    }

    private var sessionViewWithChrome: some View {
        sessionContent
        .background {
            ShakeDetector(
                isEnabled: editingCard == nil && !practiceMode && !displayingCompletion
            ) {
                Task { await undoLastAction() }
            }
        }
        .accessibilityAction(named: Text("Undo Last Study Action")) {
            Task { await undoLastAction() }
        }
        .navigationTitle(practiceMode ? "Toughest Practice" : "")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
        .navigationBarBackButtonHidden(mode == .reviews)
        .preference(key: AppSessionFocusKey.self, value: [appModeDestination: !displayingCompletion])
        .toolbarBackground(StudyWashiStyle.desk, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { lessonDismissToolbar }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 0) { endSessionControl }.fixedSize()
            }
                .sharedBackgroundVisibility(.hidden)
            if practiceMode {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back to wrap-up") {
                        exitPracticeMode()
                    }
                }
            }
            if let card,
               showingAnswer,
               store.masteryAnimation == nil,
               !practiceMode,
               !displayingCompletion
            {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if StudyCardDraft.CardType(rawValue: card.cardType) != nil {
                        Button {
                            player.stop()
                            editingCard = card
                        } label: {
                            Image(systemName: "pencil").foregroundStyle(StudyWashiStyle.ink)
                        }
                        .accessibilityLabel("Edit card")
                        .accessibilityIdentifier("StudyAnswerEditButton")
                        .disabled(selectedGrade != nil || submittingCardActionIDs.contains(card.id))
                    }
                    if mode == .reviews {
                        reviewActionsMenu(card: card)
                            .disabled(selectedGrade != nil)
                    }
                }
            }
            if let card, !lessonPreview, !displayingCompletion, !practiceComplete, store.masteryAnimation == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    toolbarReplay(card)
                        .buttonStyle(.plain)
                        .foregroundStyle(StudyWashiStyle.ink)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    private var canEndSession: Bool {
        selectedGrade == nil && submittingReviewCardIDs.isEmpty && submittingCardActionIDs.isEmpty && store.masteryAnimation == nil
    }

    @ViewBuilder
    private var endSessionControl: some View {
        if mode == .reviews ? !displayingCompletion && !practiceMode : !allowsLessonDismissal {
            Button {
                if mode == .reviews { endReviewSession() }
                else { player.stop(); dismiss() }
            } label: {
                Text("End session")
                    .font(StudyWashiStyle.actionFont)
                    .foregroundStyle(JournalBrandStyle.spine)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!canEndSession)
            .accessibilityIdentifier("StudyEndSessionButton")
        }
    }

    private var sessionViewWithLifecycle: some View {
        sessionViewWithChrome
        .task {
            startTimeTracking()
            sessionReviewRecords = []
            practiceCards = nil
            practiceInitialCount = 0
            resetCardTimer()
            if mode == .lessons {
                guard store.beginLessonSessionPresentation(
                    presentationID: lessonPresentationID,
                    cohortID: lessonCohortID,
                    pileID: pileID
                ) else { return }
                await loadLessonBatch()
            } else {
                store.beginSessionFailureTracking()
                _ = try? await store.refreshSession()
            }
        }
        .onChange(of: reviewSessionComplete) { _, isComplete in
            guard isComplete, !sessionWasEnded else { return }
            prepareSessionCompletion()
        }
        .onChange(of: sessionReviewRecords) { _, records in
            wrapUpSummary = StudySessionWrapUpSummary.build(from: records)
        }
        .onChange(of: card?.id) { _, newCardID in
            selectedGrade = nil
            player.stop()
            if let restoredCardID = answerRestoredByUndoCardID {
                if newCardID?.lowercased() == restoredCardID.lowercased() {
                    answerRestoredByUndoCardID = nil
                    return
                }
            }
            guard !isUndoing else { return }
            showingAnswer = false
            resetCardTimer()
            didAutoplayAnswerForCardID = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startTimeTracking()
                cardTimer.resume(at: .now)
            } else {
                cardTimer.pause(at: .now)
                timeStore?.stop(activity: .cardReview, source: .automatic)
            }
        }
        .task(id: promptRecording) { await loadPromptRecording(promptRecording) }
        .task(id: card?.presentation.back.audioURL) {
            answerFile = nil
            guard let remoteURL = card?.presentation.back.audioURL else { return }
            let resolvedURL = await store.playableMediaURL(for: remoteURL)
            guard !Task.isCancelled else { return }
            answerFile = (remoteURL, resolvedURL)
            if let cardID = card?.id {
                autoplayAnswerAudioIfReady(cardID: cardID)
            }
        }
        .onDisappear {
            timeStore?.stop(activity: .cardReview, source: .automatic)
            player.stop()
            store.dismissMasteryAnimation()
            if mode == .lessons {
                store.endLessonSessionPresentation(presentationID: lessonPresentationID)
            }
        }
        .outsideDismissibleSheet(item: $editingCard, onDismiss: {
            startTimeTracking()
        }) { card in
            CardEditorView(
                store: store,
                player: player,
                card: card,
                serverDraft: nil,
                timeStore: timeStore
            )
        }
        .outsideDismissibleSheet(item: $cardPendingSetDue) { card in
            StudySetDueView { mode, dueAt in
                cardPendingSetDue = nil
                submitCardAction(.setDue, card: card, mode: mode, dueAt: dueAt)
            }
        }
        .confirmationDialog(
            "Forget this card?",
            isPresented: Binding(
                get: { cardPendingForget != nil },
                set: { if !$0 { cardPendingForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget and Reset Progress", role: .destructive) {
                guard let card = cardPendingForget else { return }
                cardPendingForget = nil
                submitCardAction(.forget, card: card)
            }
            Button("Cancel", role: .cancel) {
                cardPendingForget = nil
            }
        } message: {
            Text("This resets the card’s scheduling progress and returns it to the new-card queue.")
        }
        .alert(
            "Unable to Undo",
            isPresented: Binding(
                get: { undoErrorMessage != nil },
                set: { if !$0 { undoErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(undoErrorMessage ?? "The last study action could not be undone.")
        }
        .alert(
            "Card Action Failed",
            isPresented: Binding(
                get: { cardActionErrorMessage != nil },
                set: { if !$0 { cardActionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cardActionErrorMessage ?? "The card’s review schedule could not be updated.")
        }
    }

    private var offlineReviewCompletionMessage: String {
        let count = store.pendingOfflineReviewCount
        guard count > 0 else { return "Your completed reviews are saved." }
        return "\(count) offline \(count == 1 ? "review is" : "reviews are") safely queued for sync."
    }

    private func startTimeTracking() {
        timeStore?.start(
            activity: .cardReview,
            source: .automatic,
            name: mode == .lessons ? "Lessons" : "Card reviews"
        )
    }

    private func resetCardTimer() {
        cardTimer.reset(at: .now, isRunning: scenePhase == .active)
    }

    @ViewBuilder
    private var lessonPreviewContent: some View {
        if loadingLessons {
            ProgressView("Loading lesson…")
                .frame(maxHeight: .infinity)
        } else if let lessonLoadErrorMessage {
            ContentUnavailableView {
                Label("Lesson unavailable", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(lessonLoadErrorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadLessonBatch() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        } else if store.cards.isEmpty {
            ContentUnavailableView(
                "No cards waiting",
                systemImage: "sparkles",
                description: Text("There are no cards waiting for a lesson.")
            )
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Preview this lesson")
                        .font(.title2.bold())
                    Text("Study this batch first. The quiz contains only these cards.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if store.cards.indices.contains(lessonPreviewIndex) {
                        let previewCard = store.cards[lessonPreviewIndex]
                        VStack(spacing: 8) {
                            Text(
                                "Card \(lessonPreviewIndex + 1) of \(store.cards.count)"
                            )
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            if let heading = previewCard.presentation.back.heading
                                ?? previewCard.presentation.front.heading
                            {
                                StudyRubyText(
                                    heading,
                                    knownKanji: store.knownKanji,
                                    pointSize: 28,
                                    weight: .semibold,
                                    color: UIColor(StudyWashiStyle.ink),
                                    readingColor: UIColor(StudyWashiStyle.secondaryInk)
                                )
                            }
                            lessonAudioButton(for: previewCard)
                            ForEach(previewCard.presentation.back.textBlocks.prefix(2)) { block in
                                Text(block.text)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(StudyWashiStyle.ink)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.white.opacity(0.8), in: .rect(cornerRadius: 16))
                    }
                    HStack {
                        Button("Previous") {
                            lessonPreviewIndex = max(0, lessonPreviewIndex - 1)
                        }
                        .disabled(lessonPreviewIndex == 0)

                        Spacer()

                        if lessonPreviewIndex == store.cards.count - 1 {
                            Button("Start Quiz") {
                                lessonPreview = false
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        } else {
                            Button("Next") {
                                lessonPreviewIndex = min(
                                    store.cards.count - 1,
                                    lessonPreviewIndex + 1
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }
                    }
                    .controlSize(.large)
                }
            }
        }
    }

    @ViewBuilder
    private func lessonAudioButton(for card: StudyCard) -> some View {
        if let audioURL = card.audioURL {
            let trackID = "study-lesson-\(card.id)"
            StudyCardAudioButton(
                remoteURL: audioURL,
                trackID: trackID,
                label: "Play card audio",
                autoplay: false,
                store: store,
                player: player
            )
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityIdentifier("StudyLessonAudioButton")
            .accessibilityValue(player.isCurrent(trackID) && player.isPlaying ? "Playing" : "Not playing")
            .id("\(card.id)|\(audioURL.absoluteString)")
            .onDisappear {
                if player.isCurrent(trackID) { player.stop() }
            }
        }
    }

    @MainActor
    private func loadLessonBatch() async {
        guard !loadingLessons else { return }
        loadingLessons = true
        lessonPreview = true
        lessonPreviewIndex = 0
        lessonLoadErrorMessage = nil
        store.beginSessionFailureTracking()
        defer { loadingLessons = false }
        do {
            try await store.refreshLessons()
        } catch {
            lessonLoadErrorMessage = error.localizedDescription
        }
    }

    private var wrapUpContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(ConvoLabTheme.cyan, in: .circle)

                VStack(spacing: 4) {
                    Text("Nice work")
                        .font(.largeTitle.bold())
                        .foregroundStyle(StudyWashiStyle.ink)
                    Text(
                        reviewSessionComplete
                            ? "You’re caught up for today."
                            : "Here’s what you reviewed this session."
                    )
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    wrapUpMetric(
                        value: String(wrapUpSummary.reviewsCompleted),
                        label: "Reviews"
                    )
                    wrapUpMetric(
                        value: wrapUpSummary.firstPassRecall.map {
                            "\(Int(($0 * 100).rounded()))%"
                        } ?? "—",
                        label: "First-pass recall"
                    )
                }

                HStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.green, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Newly stabilized")
                            .font(.headline)
                        Text(stabilizedCardDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(String(wrapUpSummary.newlyStabilizedCards.count))
                        .font(.title.bold())
                        .foregroundStyle(.green)
                }
                .padding()
                .background(.white.opacity(0.85), in: .rect(cornerRadius: 18))

                if !wrapUpSummary.toughestCards.isEmpty {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Toughest this session")
                                .font(.headline)
                            Spacer()
                            Button("Practice \(wrapUpSummary.toughestCards.count)") {
                                startToughestPractice()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(StudyWashiStyle.ink)
                            .accessibilityIdentifier("StudyToughestPracticeButton")
                        }
                        .padding(.bottom, 6)

                        ForEach(wrapUpSummary.toughestCards) { item in
                            Divider()
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.card.promptText)
                                        .font(.body.bold())
                                        .lineLimit(1)
                                    Text(item.card.answerText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(toughCardReason(item))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(ConvoLabTheme.coral)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .padding()
                    .background(.white.opacity(0.85), in: .rect(cornerRadius: 18))
                    .accessibilityIdentifier("StudyToughestSection")
                }

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudyWashiStyle.ink)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("StudyWrapUpDoneButton")
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("StudySessionWrapUp")
    }

    private func wrapUpMetric(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.largeTitle.bold())
                .foregroundStyle(StudyWashiStyle.ink)
                .monospacedDigit()
            Text(label.uppercased())
                .font(.caption2.bold())
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 82)
        .padding(.horizontal, 8)
        .background(.white.opacity(0.85), in: .rect(cornerRadius: 18))
    }

    private var stabilizedCardDescription: String {
        let cards = wrapUpSummary.newlyStabilizedCards
        if cards.isEmpty {
            return "No cards crossed into week-plus stability this time."
        }
        return cards.map(\.promptText).joined(separator: " · ")
    }

    private func toughCardReason(_ item: StudySessionToughCard) -> String {
        let seconds = max(1, Int((Double(item.durationMilliseconds) / 1_000).rounded()))
        if item.missCount == 0 { return "\(seconds) sec" }
        let missLabel = item.missCount == 1 ? "1 miss" : "\(item.missCount) misses"
        return "\(missLabel) · \(seconds) sec"
    }

    private var practiceCompleteContent: some View {
        ContentUnavailableView {
            Label("Practice complete", systemImage: "checkmark.seal.fill")
        } description: {
            Text("Nothing here changed your review schedule.")
        } actions: {
            Button("Back to wrap-up") {
                exitPracticeMode()
            }
            .buttonStyle(.borderedProminent)
            .tint(StudyWashiStyle.ink)
        }
        .accessibilityIdentifier("StudyPracticeComplete")
    }

    private func startToughestPractice() {
        let cards = wrapUpSummary.toughestCards.map(\.card)
        guard !cards.isEmpty else { return }
        player.stop()
        showingAnswer = false
        practiceInitialCount = cards.count
        practiceCards = cards
        resetCardTimer()
        didAutoplayAnswerForCardID = nil
    }

    private func exitPracticeMode() {
        player.stop()
        showingAnswer = false
        practiceCards = nil
        practiceInitialCount = 0
        resetCardTimer()
        didAutoplayAnswerForCardID = nil
    }

    @ViewBuilder
    private func promptFace(_ face: StudyCardPresentation.Face) -> some View {
        VStack(spacing: 18) {
            if let imageURL = face.imageURL {
                StudyCardImage(remoteURL: imageURL, accessibilityLabel: face.supportingText ?? "Study prompt image", store: store)
            }
            if face.isMediaLed, face.imageURL == nil, let recording = promptRecording {
                promptReplay(recording, prominent: true)
            } else {
                if let heading = face.heading {
                    StudyReadingHeading(text: heading, knownKanji: store.knownKanji)
                }
                if let supportingText = face.supportingText {
                    Text(supportingText)
                        .font(.custom("CrimsonPro-Regular", size: 24, relativeTo: .title2))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(StudyWashiStyle.ink)
                }
            }
        }
    }

    private var promptRecording: StudyPromptRecording? {
        guard !showingAnswer, !lessonPreview, !displayingCompletion,
              let card, let url = card.presentation.front.audioURL else { return nil }
        return StudyPromptRecording(cardID: card.id, url: url)
    }

    private func loadPromptRecording(_ recording: StudyPromptRecording?) async {
        promptFile = nil
        guard let recording, let file = await store.playableMediaURL(for: recording.url),
              !Task.isCancelled, recording == promptRecording else { return }
        promptFile = (recording, file)
        if Self.shouldAutoplayPromptAudio(cardID: recording.cardID, currentCardID: card?.id,
                                         cardAllowsAutoplay: card?.shouldAutoplayPromptAudio == true,
                                         hasMasteryAnimation: store.masteryAnimation != nil) {
            player.play(url: file, trackID: recording.trackID)
        }
    }

    private func revealAnswer(_ card: StudyCard) {
        player.stop()
        if !practiceMode { pushUndo(.reveal(cardID: card.id)) }
        showingAnswer = true
        autoplayAnswerAudioIfReady(cardID: card.id)
    }

    @ViewBuilder
    private func promptReplay(_ recording: StudyPromptRecording, prominent: Bool) -> some View {
        let playing = player.isCurrent(recording.trackID) && player.isPlaying
        let replay = Button {
            guard let promptFile, promptFile.recording == recording else { return }
            player.play(url: promptFile.file, trackID: recording.trackID)
        } label: {
            if prominent { StudySpeakerIcon(playing: playing) }
            else {
                StudyReplayGlyph(playing: playing)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
        }
        .accessibilityLabel(prominent ? "Play prompt audio" : "Replay prompt audio")
        .accessibilityValue(playing ? "Playing" : "Not playing")
        .disabled(promptFile?.recording != recording || player.isBlockedByLongFormAudio)
        if prominent { replay.buttonStyle(StudyWashiAudioButtonStyle(playing: playing)) }
        else { replay }
    }

    @ViewBuilder
    private func toolbarReplay(_ card: StudyCard) -> some View {
        if let recording = promptRecording {
            promptReplay(recording, prominent: false)
        } else if card.presentation.back.audioURL != nil {
            let playing = player.isCurrent("study-answer-\(card.id)") && player.isPlaying
            Button {
                if showingAnswer { playAnswerAudio(cardID: card.id) }
                else { revealAnswer(card) }
            } label: {
                HStack(spacing: 4) {
                    StudyReplayGlyph(playing: playing)
                    if !showingAnswer { Text("Hear answer").font(.caption) }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
            }
            .accessibilityLabel(showingAnswer ? "Play answer audio" : "Hear answer")
            .accessibilityValue(playing ? "Playing" : "Not playing")
            .accessibilityIdentifier("StudyAnswerAudioButton")
            .accessibilityHint(answerAudioAccessibilityHint)
            .disabled(answerAudioLocalURL == nil || player.isBlockedByLongFormAudio)
        }
    }

    private func gradeButtons(card: StudyCard) -> some View {
        LazyVGrid(columns: Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: dynamicTypeSize.isAccessibilitySize ? 2 : 4
        ), spacing: 8) {
            gradeButton("Again", rating: .again, color: ConvoLabTheme.coral, card: card)
            gradeButton("Hard", rating: .hard, color: .orange, card: card)
            gradeButton("Good", rating: .good, color: ConvoLabTheme.cyan, card: card)
            gradeButton("Easy", rating: .easy, color: StudyWashiStyle.good, card: card)
        }
        .frame(maxWidth: 360)
        .task(id: selectedGrade) {
            guard let rating = selectedGrade else { return }
            do { try await Task.sleep(for: .milliseconds(420)) } catch { return }
            guard self.card?.id == card.id, showingAnswer else { return }
            submitGrade(rating, card: card)
            selectedGrade = nil
        }
        .onDisappear { selectedGrade = nil }

    }

    private func reviewActionsMenu(card: StudyCard) -> some View {
        Menu {
            Button {
                submitCardAction(.suspend, card: card)
            } label: {
                Label("Suspend", systemImage: "pause.circle")
            }
            Button {
                cardPendingSetDue = card
            } label: {
                Label("Set Due", systemImage: "calendar.badge.clock")
            }
            Button(role: .destructive) {
                cardPendingForget = card
            } label: {
                Label("Forget", systemImage: "arrow.counterclockwise")
            }
        } label: {
            if submittingCardActionIDs.contains(card.id) {
                ProgressView()
            } else {
                Image(systemName: "ellipsis.circle").foregroundStyle(StudyWashiStyle.ink)
            }
        }
        .disabled(
            !submittingReviewCardIDs.isEmpty
                || !submittingCardActionIDs.isEmpty
                || isUndoing
                || editingCard != nil
        )
        .accessibilityLabel("Card actions")
        .accessibilityIdentifier("StudyAnswerCardActionsButton")
    }

    private func submitCardAction(
        _ action: StudyCardActionName,
        card: StudyCard,
        mode: StudyCardSetDueMode? = nil,
        dueAt: Date? = nil
    ) {
        guard submittingCardActionIDs.insert(card.id).inserted else { return }
        player.stop()
        Task {
            do {
                _ = try await store.performCardAction(
                    action,
                    on: card,
                    mode: mode,
                    dueAt: dueAt
                )
                showingAnswer = false
                didAutoplayAnswerForCardID = nil
                resetCardTimer()
            } catch is CancellationError {
                // Navigation or an account change cancelled this action.
            } catch let error as URLError where error.code == .cancelled {
                // Navigation or an account change cancelled this action.
            } catch {
                cardActionErrorMessage = error.localizedDescription
            }
            submittingCardActionIDs.remove(card.id)
        }
    }

    private func gradeButton(
        _ title: String,
        rating: ReviewRating,
        color: Color,
        card: StudyCard
    ) -> some View {
        Button {
            guard selectedGrade == nil else { return }
            selectedGrade = rating
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if selectedGrade == rating { Image(systemName: "checkmark").font(.caption.bold()) }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(Text(title))
        .buttonStyle(StudyWashiGradeButtonStyle(color: color, selected: selectedGrade == rating))
        .frame(maxWidth: .infinity)
        .disabled(
            !submittingReviewCardIDs.isEmpty
                || submittingCardActionIDs.contains(card.id)
                || isUndoing
                || store.masteryAnimation != nil
        )
    }

    private func submitGrade(_ rating: ReviewRating, card: StudyCard) {
        guard showingAnswer else { return }
        if practiceMode {
            player.stop()
            didAutoplayAnswerForCardID = nil
            practiceCards = StudySessionPracticeQueue.applying(
                rating,
                to: practiceCards ?? []
            )
            showingAnswer = false
            resetCardTimer()
            return
        }
        if mode == .lessons, rating == .again {
            player.stop()
            didAutoplayAnswerForCardID = nil
            store.retryLessonCard(card)
            showingAnswer = false
            resetCardTimer()
            return
        }
        guard submittingReviewCardIDs.insert(card.id).inserted else { return }
        let reviewedAt = Date.now
        if rating == .again {
            didAutoplayAnswerForCardID = nil
        }
        let duration = cardTimer.duration(at: reviewedAt)
        let durationMilliseconds = Int(duration * 1_000)
        Task {
            let stagedReview = await store.recordReviewResult(
                card: card,
                rating: rating,
                duration: .milliseconds(Int64(durationMilliseconds)),
                reviewedAt: reviewedAt
            )
            if let stagedReview {
                pushUndo(
                    .grade(
                        eventID: stagedReview.eventID,
                        cardBefore: stagedReview.cardBefore
                    )
                )
                sessionReviewRecords.append(
                    StudySessionReviewRecord(
                        id: stagedReview.eventID,
                        cardBefore: stagedReview.cardBefore,
                        cardAfter: stagedReview.cardAfter,
                        rating: rating,
                        durationMilliseconds: durationMilliseconds,
                        reviewedAt: reviewedAt
                    )
                )
            }
            submittingReviewCardIDs.remove(card.id)
        }
    }

    @ViewBuilder
    private var masteryFeedbackLane: some View {
        if !practiceMode, let animation = store.masteryAnimation {
            MasteryReviewAnimation(
                label: animation.label,
                fromLevel: animation.fromLevel,
                toLevel: animation.toLevel,
                passed: animation.passed
            ) {
                guard store.masteryAnimation?.id == animation.id else {
                    return
                }
                store.dismissMasteryAnimation()
            }
            .id(animation.id)
            .frame(height: MasteryReviewAnimation.feedbackLaneHeight)
            .background(StudyWashiStyle.desk, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 16)
            .allowsHitTesting(false)
        }
    }

    private var answerAudioLocalURL: URL? {
        guard let answerFile, answerFile.source == card?.presentation.back.audioURL else { return nil }
        return answerFile.local
    }

    private func playAnswerAudio(cardID: String) {
        guard let answerAudioLocalURL else { return }
        player.play(url: answerAudioLocalURL, trackID: "study-answer-\(cardID)")
    }

    private func autoplayAnswerAudioIfReady(cardID: String) {
        guard
            showingAnswer,
            didAutoplayAnswerForCardID != cardID,
            answerAudioLocalURL != nil
        else {
            return
        }
        didAutoplayAnswerForCardID = cardID
        playAnswerAudio(cardID: cardID)
    }

    static func shouldAutoplayPromptAudio(
        cardID: String,
        currentCardID: String?,
        cardAllowsAutoplay: Bool,
        hasMasteryAnimation: Bool
    ) -> Bool {
        cardID == currentCardID
            && cardAllowsAutoplay
            && !hasMasteryAnimation
    }

    private func pushUndo(_ action: StudyUndoAction) {
        undoActions.append(action)
        if undoActions.count > 50 {
            undoActions.removeFirst(undoActions.count - 50)
        }
    }

    @MainActor
    private func undoLastAction() async {
        guard
            !practiceMode,
            !displayingCompletion,
            !isUndoing,
            submittingReviewCardIDs.isEmpty,
            submittingCardActionIDs.isEmpty,
            store.masteryAnimation == nil,
            editingCard == nil,
            let action = undoActions.popLast()
        else {
            return
        }

        player.stop()
        switch action {
        case let .reveal(cardID):
            guard card?.id == cardID, showingAnswer else { return }
            showingAnswer = false
            didAutoplayAnswerForCardID = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case let .grade(eventID, cardBefore):
            isUndoing = true
            defer { isUndoing = false }
            if card?.id.lowercased() != cardBefore.id.lowercased() {
                answerRestoredByUndoCardID = cardBefore.id
            }
            do {
                try await store.undoReview(eventID: eventID, cardBefore: cardBefore)
                sessionReviewRecords.removeAll { $0.id == eventID }
                showingAnswer = true
                resetCardTimer()
                didAutoplayAnswerForCardID = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                answerRestoredByUndoCardID = nil
                undoActions.append(action)
                undoErrorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private var answerAudioAccessibilityHint: String {
        if player.isBlockedByLongFormAudio {
            return "Pause Daily Audio before playing a study card."
        }
        if let answerFile, answerFile.source == card?.presentation.back.audioURL, answerFile.local == nil {
            return "Audio is not available offline."
        }
        return "Plays downloaded study audio."
    }

    private func endReviewSession() {
        // Grades are already persisted; onDisappear stops and saves the automatic timer.
        // Manual exit returns home, while natural completion still shows the wrap-up.
        player.stop()
        dismiss()
    }

    private func prepareSessionCompletion() {
        guard !sessionWasEnded else { return }
        sessionWasEnded = true
    }

}

private enum StudyUndoAction {
    case reveal(cardID: String)
    case grade(eventID: String, cardBefore: StudyCard)
}

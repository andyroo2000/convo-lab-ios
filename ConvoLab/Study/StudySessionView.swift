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
    @State private var gradeFeedback: (card: StudyCard, rating: ReviewRating)?
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
    @State private var reviewHistory = StudyReviewHistory()
    @State private var sessionWasEnded = false
    @State private var wrapUpSummary: StudySessionWrapUpSummary
    @State private var practiceCards: [StudyCard]?
    @State private var batchRetryIDs: Set<String> = []
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

    private var selectedGrade: ReviewRating? { gradeFeedback?.rating ?? store.masteryAnimation?.rating }

    private var card: StudyCard? {
        if let gradeFeedback { return gradeFeedback.card }
        if let practiceCards {
            return practiceCards.first
        }
        return store.masteryAnimation?.card ?? store.cards.first
    }

    private var practiceMode: Bool { practiceCards != nil }

    private var practiceComplete: Bool { selectedGrade == nil && practiceCards?.isEmpty == true }

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
            && selectedGrade == nil
            && !reviewHistory.records.isEmpty
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
        return store.reviewProgress(for: reviewHistory)
    }

    private var showsCardHeader: Bool {
        card != nil && !lessonPreview && !practiceComplete && (practiceMode || !displayingCompletion)
    }

    private var queueCounts: StudyQueueCountsView {
        if practiceMode || mode == .lessons {
            let batch = practiceCards ?? store.cards
            let retries = batch.count { batchRetryIDs.contains($0.id) }
            return StudyQueueCountsView(failed: retries, remaining: batch.count - retries)
        }
        let counts = store.reviewQueueCounts
        return StudyQueueCountsView(failed: counts.failed, remaining: counts.remaining)
    }

    private var sessionContent: some View {
        VStack(spacing: 0) {
            if showsCardHeader, let card {
                StudyCardProgressView(progress: sessionProgress)
                cardHeader(card)
                    .padding(.horizontal, 12)
            }
            VStack(spacing: 10) { activeSessionContent }
                .padding()
        }
        .background { StudyWashiBackground() }
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
                if showingAnswer || selectedGrade != nil {
                    StudySessionAnswer(face: presentation.back, store: store)
                } else {
                    promptFace(presentation.front)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Flashcard")

            if showingAnswer || selectedGrade != nil {
                gradeButtons(card: card)
                    .overlay(alignment: .top) {
                        masteryFeedbackLane
                            .fixedSize()
                            .padding(.bottom, 12)
                            .frame(height: 0, alignment: .bottom)
                            .allowsHitTesting(false)
                    }
            } else {
                Button("Reveal answer") { revealAnswer(card) }
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
        .toolbar(showsCardHeader ? .hidden : .visible, for: .navigationBar)
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
        }
    }

    private func cardHeader(_ card: StudyCard) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                sessionNavigation
                queueCounts
                Spacer(minLength: 2)
                answerActions(card)
            }.fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                HStack { sessionNavigation; Spacer(); answerActions(card) }
                queueCounts.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var sessionNavigation: some View {
        if practiceMode {
            Button { exitPracticeMode() } label: {
                Text("Back to wrap-up").frame(minHeight: 44)
            }
        } else if mode == .lessons && allowsLessonDismissal {
            Button { dismiss() } label: {
                Text("Close").frame(minWidth: 44, minHeight: 44)
            }
                .accessibilityIdentifier("StudyCloseLessonButton")
        } else {
            endSessionControl
        }
    }

    @ViewBuilder
    private func answerActions(_ card: StudyCard) -> some View {
        if showingAnswer, store.masteryAnimation == nil {
            if !practiceMode {
                if StudyCardDraft.CardType(rawValue: card.cardType) != nil {
                    Button {
                        player.stop()
                        editingCard = card
                    } label: {
                        Image(systemName: "pencil").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Edit card")
                    .accessibilityIdentifier("StudyAnswerEditButton")
                    .disabled(selectedGrade != nil || submittingCardActionIDs.contains(card.id))
                }
                if mode == .reviews {
                    reviewActionsMenu(card: card).disabled(selectedGrade != nil)
                }
            }
            toolbarReplay(card)
                .buttonStyle(.plain)
                .disabled(selectedGrade != nil)
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
                    .padding(.horizontal, 13)
                    .padding(.vertical, 3)
                    .overlay { Capsule().strokeBorder(StudyWashiStyle.green.opacity(0.65)) }
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
            reviewHistory.records = []
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
        .onChange(of: reviewHistory.revision) {
            wrapUpSummary = StudySessionWrapUpSummary.build(from: reviewHistory.records)
        }
        .onChange(of: card?.id) { _, newCardID in
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
            gradeFeedback = nil
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
        batchRetryIDs.removeAll()
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
                Image("ReviewTutorHana")
                    .resizable().scaledToFit()
                    .frame(width: 96, height: 96)
                    .background(.white, in: Circle()).clipShape(Circle())
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("おつかれさまでした！")
                        .font(.custom("Georgia", size: 30, relativeTo: .title))
                        .accessibilityAddTraits(.isHeader)
                    Text("Nice work")
                        .font(StudyWashiStyle.actionFont.italic())
                        .foregroundStyle(StudyWashiStyle.muted)
                }
                Text(reviewSessionComplete ? "You’re caught up for today." : "Here’s what you reviewed this session.")
                    .font(StudyWashiStyle.actionFont)
                Divider()

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

                Divider()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(StudyRevealButtonStyle())
                .accessibilityIdentifier("StudyWrapUpDoneButton")
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(StudyWashiStyle.ink)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("StudySessionWrapUp")
    }

    private func wrapUpMetric(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.custom("CrimsonPro-Regular", size: 36, relativeTo: .largeTitle))
                .foregroundStyle(StudyWashiStyle.ink)
                .monospacedDigit()
            Text(label)
                .font(StudyWashiStyle.actionFont)
                .foregroundStyle(StudyWashiStyle.secondaryInk)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
        batchRetryIDs.removeAll()
        practiceInitialCount = cards.count
        practiceCards = cards
        resetCardTimer()
        didAutoplayAnswerForCardID = nil
    }

    private func exitPracticeMode() {
        gradeFeedback = nil
        player.stop()
        showingAnswer = false
        practiceCards = nil
        batchRetryIDs.removeAll()
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
            if face.isMediaLed, let recording = promptRecording {
                promptReplay(recording)
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
        guard selectedGrade == nil, !showingAnswer, !lessonPreview, (practiceMode || !displayingCompletion),
              let card, card.shouldAutoplayPromptAudio, let url = card.presentation.front.audioURL else { return nil }
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

    private func promptReplay(_ recording: StudyPromptRecording) -> some View {
        let playing = player.isCurrent(recording.trackID) && player.isPlaying
        return Button {
            guard let promptFile, promptFile.recording == recording else { return }
            player.play(url: promptFile.file, trackID: recording.trackID)
        } label: {
            StudySpeakerIcon(playing: playing)
        }
        .accessibilityLabel("Play prompt audio")
        .accessibilityValue(playing ? "Playing" : "Not playing")
        .disabled(promptFile?.recording != recording || player.isBlockedByLongFormAudio)
        .buttonStyle(StudyWashiAudioButtonStyle(playing: playing))
    }

    @ViewBuilder
    private func toolbarReplay(_ card: StudyCard) -> some View {
        if card.presentation.back.audioURL != nil {
            let playing = player.isCurrent("study-answer-\(card.id)") && player.isPlaying
            Button { playAnswerAudio(cardID: card.id) } label: {
                StudyReplayGlyph(playing: playing)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Play answer audio")
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
            gradeButton("Again", rating: .again, card: card)
            gradeButton("Hard", rating: .hard, card: card)
            gradeButton("Good", rating: .good, card: card)
            gradeButton("Easy", rating: .easy, card: card)
        }
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 480 : 316)
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
            selectedGrade != nil
                || !submittingReviewCardIDs.isEmpty
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
        guard selectedGrade == nil, submittingCardActionIDs.insert(card.id).inserted else { return }
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
        card: StudyCard
    ) -> some View {
        Button {
            submitGrade(rating, card: card)
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selectedGrade == rating ? .isSelected : [])
        .buttonStyle(StudyWashiGradeButtonStyle(rating: rating, selected: selectedGrade == rating))
        .frame(maxWidth: .infinity)
        .disabled(
            selectedGrade != nil
                || !submittingReviewCardIDs.isEmpty
                || submittingCardActionIDs.contains(card.id)
                || isUndoing
                || store.masteryAnimation != nil
        )
    }

    private func submitGrade(_ rating: ReviewRating, card: StudyCard) {
        guard showingAnswer, selectedGrade == nil, submittingReviewCardIDs.isEmpty else { return }
        player.stop()
        if rating == .again, practiceMode || mode == .lessons { batchRetryIDs.insert(card.id) }
        gradeFeedback = (card, rating)
        let confirmationEnds = ContinuousClock.now + .milliseconds(650)
        let repeatingLesson = mode == .lessons && rating == .again
        if practiceMode || repeatingLesson {
            Task {
                try? await Task.sleep(until: confirmationEnds, clock: .continuous)
                advanceLocalBatch(card: card, rating: rating)
            }
            return
        }
        submittingReviewCardIDs.insert(card.id)
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
                let wasBatchRetry = batchRetryIDs.remove(card.id) != nil
                pushUndo(
                    .grade(
                        eventID: stagedReview.eventID,
                        cardBefore: stagedReview.cardBefore,
                        wasBatchRetry: wasBatchRetry
                    )
                )
                reviewHistory.records.append(
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
            try? await Task.sleep(until: confirmationEnds, clock: .continuous)
            gradeFeedback = nil
            submittingReviewCardIDs.remove(card.id)
        }
    }

    private func advanceLocalBatch(card: StudyCard, rating: ReviewRating) {
        guard gradeFeedback?.card.id == card.id else { return }
        if practiceMode {
            if rating != .again { batchRetryIDs.remove(card.id) }
            practiceCards = StudySessionPracticeQueue.applying(rating, to: practiceCards ?? [])
        } else {
            store.retryLessonCard(card)
        }
        didAutoplayAnswerForCardID = nil
        showingAnswer = false
        gradeFeedback = nil
        resetCardTimer()
    }

    @ViewBuilder
    private var masteryFeedbackLane: some View {
        if gradeFeedback == nil, !practiceMode, let animation = store.masteryAnimation {
            MasteryReviewAnimation(
                label: animation.label,
                fromLevel: animation.fromLevel,
                toLevel: animation.toLevel
            ) {
                guard store.masteryAnimation?.id == animation.id else {
                    return
                }
                showingAnswer = false
                gradeFeedback = nil
                store.dismissMasteryAnimation()
            }
            .id(animation.id)
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
            selectedGrade == nil,
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
        case let .grade(eventID, cardBefore, wasBatchRetry):
            isUndoing = true
            defer { isUndoing = false }
            if card?.id.lowercased() != cardBefore.id.lowercased() {
                answerRestoredByUndoCardID = cardBefore.id
            }
            do {
                try await store.undoReview(eventID: eventID, cardBefore: cardBefore)
                if wasBatchRetry { batchRetryIDs.insert(cardBefore.id) }
                reviewHistory.records.removeAll { $0.id == eventID }
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
    case grade(eventID: String, cardBefore: StudyCard, wasBatchRetry: Bool)
}

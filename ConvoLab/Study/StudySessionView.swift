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
    let milestoneStore: StudyMilestoneStore?
    let restoredCompletion: StudyMilestoneCompletion?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var showingAnswer = false
    @State private var cardTimer = StudySessionCardTimer(startedAt: .now)
    @State private var submittingReviewCardIDs: Set<String> = []
    @State private var answerAudioLocalURL: URL?
    @State private var didAttemptAnswerAudioLoad = false
    @State private var didAutoplayAnswerForCardID: String?
    @State private var editingCard: StudyCard?
    @State private var undoActions: [StudyUndoAction] = []
    @State private var isUndoing = false
    @State private var undoErrorMessage: String?
    @State private var answerRestoredByUndoCardID: String?
    @State private var lessonPreview = true
    @State private var lessonPreviewIndex = 0
    @State private var loadingLessons = false
    @State private var submittingCardActionIDs: Set<String> = []
    @State private var cardPendingForget: StudyCard?
    @State private var cardPendingSetDue: StudyCard?
    @State private var cardActionErrorMessage: String?
    @State private var sessionReviewRecords: [StudySessionReviewRecord] = []
    @State private var sessionCompletion: StudyMilestoneCompletion?
    @State private var sessionWasEnded = false
    @State private var currentAwardIndex = 0
    @State private var celebrationPresented = false
    @State private var practiceCards: [StudyCard]?
    @State private var practiceInitialCount = 0

    init(
        store: StudyStore,
        player: StudyAudioPlayer,
        mode: Mode = .reviews,
        timeStore: StudyTimeStore? = nil,
        milestoneStore: StudyMilestoneStore? = nil,
        restoredCompletion: StudyMilestoneCompletion? = nil
    ) {
        self.store = store
        self.player = player
        self.mode = mode
        self.timeStore = timeStore
        self.milestoneStore = milestoneStore
        self.restoredCompletion = restoredCompletion
        _lessonPreview = State(initialValue: mode == .lessons)
        _sessionReviewRecords = State(initialValue: restoredCompletion?.records ?? [])
        _sessionCompletion = State(initialValue: restoredCompletion)
        _sessionWasEnded = State(initialValue: restoredCompletion != nil)
        _celebrationPresented = State(
            initialValue: restoredCompletion?.celebrationPresented ?? false
        )
    }

    private var card: StudyCard? {
        if let practiceCards {
            return practiceCards.first
        }
        return store.masteryAnimation?.card ?? store.cards.first
    }

    private var practiceMode: Bool { practiceCards != nil }

    private var practiceComplete: Bool { practiceCards?.isEmpty == true }

    private var wrapUpSummary: StudySessionWrapUpSummary {
        StudySessionWrapUpSummary.build(from: sessionReviewRecords)
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
        sessionWasEnded || sessionCompletion != nil || reviewSessionComplete
    }

    private var currentMilestoneAward: StudyMilestoneAward? {
        guard !celebrationPresented,
              let awards = sessionCompletion?.newAwards,
              awards.indices.contains(currentAwardIndex)
        else { return nil }
        return awards[currentAwardIndex]
    }

    private var displayedProgress: Double {
        guard let practiceCards else { return store.sessionProgress }
        guard practiceInitialCount > 0 else { return 1 }
        return Double(practiceInitialCount - practiceCards.count) / Double(practiceInitialCount)
    }

    private var sessionContent: some View {
        VStack(spacing: 10) {
            sessionProgressContent
            activeSessionContent
        }
        .padding()
        .paperBackground()
        .overlay {
            InteractivePopGestureGuard(isDisabled: mode == .reviews) {
                endReviewSession()
            }
                .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private var sessionProgressContent: some View {
        if currentMilestoneAward == nil {
            ProgressView(value: displayedProgress)
                .tint(.green)
                .accessibilityLabel(practiceMode ? "Practice progress" : "Session progress")
            masteryFeedbackLane
        }
    }

    @ViewBuilder
    private var activeSessionContent: some View {
        if let award = currentMilestoneAward {
            StudyMilestoneAwardView(award: award) {
                advanceMilestoneAward()
            }
            .id(award.id)
        } else if mode == .lessons, lessonPreview {
            lessonPreviewContent
        } else if displayingCompletion, !practiceMode {
            wrapUpContent
        } else if practiceComplete {
            practiceCompleteContent
        } else if let card {
            if practiceMode {
                Text("Practice only · results won’t affect your review schedule")
                    .font(.caption.bold())
                    .foregroundStyle(ConvoLabTheme.navy)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(ConvoLabTheme.cyan.opacity(0.16), in: .capsule)
                    .accessibilityIdentifier("StudyPracticeModeBanner")
            }
            let presentation = card.presentation
            VStack {
                Spacer()
                if showingAnswer {
                    answerFace(presentation.back, card: card)
                } else {
                    promptFace(presentation.front, cardID: card.id)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showingAnswer {
                gradeButtons(card: card)
            } else {
                Button("Show Answer") {
                    player.stop()
                    if !practiceMode {
                        pushUndo(.reveal(cardID: card.id))
                    }
                    showingAnswer = true
                    autoplayAnswerAudioIfReady(cardID: card.id)
                    Task {
                        await store.resolvePitchAccent(for: card)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(ConvoLabTheme.navy)
                .controlSize(.large)
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
                .tint(ConvoLabTheme.navy)
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
        .navigationTitle(practiceMode ? "Toughest Practice" : "Practice")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(mode == .reviews)
        .toolbar {
            if practiceMode {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back to wrap-up") {
                        exitPracticeMode()
                    }
                }
            } else if mode == .reviews,
                      restoredCompletion == nil,
                      !displayingCompletion
            {
                ToolbarItem(placement: .topBarLeading) {
                    Button("End session") {
                        endReviewSession()
                    }
                    .disabled(
                        !submittingReviewCardIDs.isEmpty
                            || !submittingCardActionIDs.isEmpty
                            || store.masteryAnimation != nil
                    )
                    .accessibilityIdentifier("StudyEndSessionButton")
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
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel("Edit card")
                        .accessibilityIdentifier("StudyAnswerEditButton")
                        .disabled(submittingCardActionIDs.contains(card.id))
                    }
                    if mode == .reviews {
                        reviewActionsMenu(card: card)
                    }
                }
            }
        }
        .task {
            if let restoredCompletion {
                sessionReviewRecords = restoredCompletion.records
                sessionCompletion = restoredCompletion
                sessionWasEnded = true
                celebrationPresented = restoredCompletion.celebrationPresented
                currentAwardIndex = 0
                return
            }
            startTimeTracking()
            sessionReviewRecords = []
            practiceCards = nil
            practiceInitialCount = 0
            resetCardTimer()
            if mode == .lessons {
                store.beginLessonSessionPresentation()
                await loadLessonBatch()
            } else {
                store.beginSessionFailureTracking()
                _ = try? await store.refreshSession()
                milestoneStore?.beginReviewSession(burnedCount: currentBurnedCount)
            }
        }
        .onChange(of: reviewSessionComplete) { _, isComplete in
            guard isComplete, sessionCompletion == nil else { return }
            prepareSessionCompletion()
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
        .task(id: card?.presentation.back.audioURL) {
            answerAudioLocalURL = nil
            didAttemptAnswerAudioLoad = false
            guard let remoteURL = card?.presentation.back.audioURL else { return }
            let resolvedURL = await store.playableMediaURL(for: remoteURL)
            guard !Task.isCancelled else { return }
            answerAudioLocalURL = resolvedURL
            didAttemptAnswerAudioLoad = true
            if let cardID = card?.id {
                autoplayAnswerAudioIfReady(cardID: cardID)
            }
        }
        .onDisappear {
            timeStore?.stop(activity: .cardReview, source: .automatic)
            player.stop()
            store.dismissMasteryAnimation()
            if mode == .lessons {
                store.endLessonSessionPresentation()
            }
        }
        .sheet(item: $editingCard, onDismiss: {
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
        .sheet(item: $cardPendingSetDue) { card in
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
                                    weight: .semibold
                                )
                            }
                            ForEach(previewCard.presentation.back.textBlocks.prefix(2)) { block in
                                Text(block.text)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
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

    @MainActor
    private func loadLessonBatch() async {
        guard !loadingLessons else { return }
        loadingLessons = true
        lessonPreview = true
        lessonPreviewIndex = 0
        store.beginSessionFailureTracking()
        defer { loadingLessons = false }
        do {
            try await store.refreshLessons()
        } catch {
            // StudyStore's normal sync surfaces connectivity errors on the home screen.
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
                        .foregroundStyle(ConvoLabTheme.navy)
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
                            .tint(ConvoLabTheme.navy)
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

                if let milestoneStore,
                   let awards = sessionCompletion?.newAwards,
                   !awards.isEmpty
                {
                    NavigationLink {
                        StudyMilestonesView(store: milestoneStore)
                    } label: {
                        StudyRecentMilestonesSection(awards: awards)
                    }
                    .buttonStyle(.plain)
                }

                Button("Done") {
                    if let completionID = sessionCompletion?.id {
                        milestoneStore?.consumeCompletion(sessionID: completionID)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(ConvoLabTheme.navy)
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
                .foregroundStyle(ConvoLabTheme.navy)
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
            .tint(ConvoLabTheme.navy)
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
    private func promptFace(_ face: StudyCardPresentation.Face, cardID: String) -> some View {
        VStack(spacing: 18) {
            if let imageURL = face.imageURL {
                StudyCardImage(
                    remoteURL: imageURL,
                    accessibilityLabel: face.supportingText ?? "Study prompt image",
                    store: store
                )
            }
            if let audioURL = face.audioURL {
                StudyCardAudioButton(
                    remoteURL: audioURL,
                    trackID: "study-prompt-\(cardID)",
                    label: face.isMediaLed ? "Replay prompt audio" : "Play prompt audio",
                    autoplay: Self.shouldAutoplayPromptAudio(
                        cardID: cardID,
                        currentCardID: card?.id,
                        cardAllowsAutoplay: card?.shouldAutoplayPromptAudio == true,
                        hasMasteryAnimation: store.masteryAnimation != nil
                    ),
                    store: store,
                    player: player
                )
            }
            if let heading = face.heading {
                StudyRubyText(
                    heading,
                    knownKanji: store.knownKanji,
                    pointSize: 38,
                    weight: .semibold
                )
            }
            if let supportingText = face.supportingText {
                Text(supportingText)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func answerFace(_ face: StudyCardPresentation.Face, card: StudyCard) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                if let heading = face.heading {
                    StudyRubyText(
                        heading,
                        knownKanji: store.knownKanji,
                        pointSize: 34,
                        weight: .semibold
                    )
                }

                if face.audioURL != nil {
                    Button {
                        playAnswerAudio(cardID: card.id)
                    } label: {
                        Label("Play answer audio", systemImage: "play.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(ConvoLabTheme.navy)
                    .disabled(
                        answerAudioLocalURL == nil || player.isBlockedByLongFormAudio
                    )
                    .accessibilityHint(answerAudioAccessibilityHint)
                    .accessibilityIdentifier("StudyAnswerAudioButton")
                }

                if let pitchAccent = face.pitchAccent {
                    StudyPitchAccentDiagram(pitchAccent: pitchAccent)
                        .accessibilityIdentifier("StudyPitchAccentDiagram")
                } else if store.resolvingPitchAccentCardIDs.contains(card.id) {
                    Text("Loading pitch accent…")
                        .font(.caption.bold())
                        .textCase(.uppercase)
                        .tracking(1)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("StudyPitchAccentLoading")
                }

                Divider()

                if let imageURL = face.imageURL {
                    StudyCardImage(
                        remoteURL: imageURL,
                        accessibilityLabel: face.textBlocks.first {
                            $0.role == .meaning
                        }?.text ?? "Answer image",
                        store: store
                    )
                }

                ForEach(face.textBlocks) { block in
                    let text = block.role == .note ? "• \(block.text)" : block.text

                    if block.role.supportsRuby {
                        StudyRubyText(
                            text,
                            knownKanji: store.knownKanji,
                            pointSize: pointSize(for: block.role),
                            color: uiColor(for: block.role)
                        )
                        .font(font(for: block.role))
                        .foregroundStyle(color(for: block.role))
                        .accessibilityElement(children: .combine)
                    } else {
                        Text(text)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .font(font(for: block.role))
                            .foregroundStyle(color(for: block.role))
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func font(for role: StudyCardPresentation.TextRole) -> Font {
        switch role {
        case .restoredText, .meaning: .title2
        case .sentenceJapanese: .title3
        case .sentenceEnglish, .note: .body
        }
    }

    private func pointSize(for role: StudyCardPresentation.TextRole) -> CGFloat {
        switch role {
        case .restoredText, .meaning: 22
        case .sentenceJapanese: 20
        case .sentenceEnglish, .note: 17
        }
    }

    private func color(for role: StudyCardPresentation.TextRole) -> Color {
        switch role {
        case .restoredText, .sentenceJapanese: .primary
        case .meaning: ConvoLabTheme.navy
        case .sentenceEnglish, .note: .secondary
        }
    }

    private func uiColor(for role: StudyCardPresentation.TextRole) -> UIColor {
        switch role {
        case .restoredText, .sentenceJapanese: .label
        case .meaning: UIColor(ConvoLabTheme.navy)
        case .sentenceEnglish, .note: .secondaryLabel
        }
    }

    private func gradeButtons(card: StudyCard) -> some View {
        HStack(spacing: 8) {
            gradeButton("Again", rating: .again, color: ConvoLabTheme.coral, card: card)
            gradeButton("Hard", rating: .hard, color: .orange, card: card)
            gradeButton("Good", rating: .good, color: ConvoLabTheme.cyan, card: card)
            gradeButton("Easy", rating: .easy, color: .green, card: card)
        }
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
                Image(systemName: "ellipsis.circle")
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
                    if mode == .reviews, let record = sessionReviewRecords.last {
                        milestoneStore?.recordReview(record)
                    }
                }
                submittingReviewCardIDs.remove(card.id)
            }
        } label: {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .frame(maxWidth: .infinity)
        .disabled(
            submittingReviewCardIDs.contains(card.id)
                || submittingCardActionIDs.contains(card.id)
                || isUndoing
                || store.masteryAnimation != nil
        )
    }

    @ViewBuilder
    private var masteryFeedbackLane: some View {
        if !practiceMode, (mode == .reviews || !lessonPreview), card != nil {
            ZStack {
                Color.clear

                if let animation = store.masteryAnimation {
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
                }
            }
            .frame(height: MasteryReviewAnimation.feedbackLaneHeight)
        }
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
                if mode == .reviews {
                    milestoneStore?.undoReview(eventID: eventID)
                }
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
        if didAttemptAnswerAudioLoad, answerAudioLocalURL == nil {
            return "Audio is not available offline."
        }
        return "Plays downloaded study audio."
    }

    private var currentBurnedCount: Int {
        store.overview?.masterySpread?.burned
            ?? store.libraryCards.filter { $0.fsrsMasteryLevel == .burned }.count
    }

    private func advanceMilestoneAward() {
        guard let completion = sessionCompletion else { return }
        if currentAwardIndex + 1 < completion.newAwards.count {
            currentAwardIndex += 1
            return
        }
        celebrationPresented = true
        milestoneStore?.markCelebrationPresented(sessionID: completion.id)
    }

    private func endReviewSession() {
        player.stop()
        guard !sessionReviewRecords.isEmpty else {
            milestoneStore?.cancelCurrentSession()
            dismiss()
            return
        }
        prepareSessionCompletion()
    }

    private func prepareSessionCompletion() {
        sessionWasEnded = true
        sessionCompletion = milestoneStore?.prepareCurrentSessionCompletion()
        currentAwardIndex = 0
        celebrationPresented = sessionCompletion?.celebrationPresented ?? true
    }
}

struct StudySetDueView: View {
    let onSubmit: (StudyCardSetDueMode, Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customDate = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick options") {
                    Button("Now") {
                        onSubmit(.now, nil)
                    }
                    Button("Tomorrow at 9:00 AM") {
                        onSubmit(.tomorrow, nil)
                    }
                }
                Section("Custom date") {
                    DatePicker(
                        "Due date",
                        selection: $customDate,
                        in: Date.now...Self.maximumCustomDate(),
                        displayedComponents: .date
                    )
                    Button("Set Custom Date") {
                        onSubmit(.customDate, Self.localNineAM(on: customDate))
                    }
                }
            }
            .navigationTitle("Set Due")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    static func localNineAM(
        on date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
    }

    private static func maximumCustomDate(
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let tenYearsFromNow = calendar.date(byAdding: .year, value: 10, to: .now) ?? .distantFuture
        return calendar.date(byAdding: .day, value: -1, to: tenYearsFromNow)
            ?? tenYearsFromNow
    }
}

private enum StudyUndoAction {
    case reveal(cardID: String)
    case grade(eventID: String, cardBefore: StudyCard)
}

private extension StudyCardPresentation.TextRole {
    var supportsRuby: Bool {
        switch self {
        case .restoredText, .sentenceJapanese, .note: true
        case .meaning, .sentenceEnglish: false
        }
    }
}

private struct StudyCardAudioButton: View {
    let remoteURL: URL
    let trackID: String
    let label: String
    let autoplay: Bool
    let store: StudyStore
    let player: StudyAudioPlayer

    @State private var localURL: URL?
    @State private var didAttemptLoad = false

    var body: some View {
        Button {
            guard let localURL else { return }
            player.play(url: localURL, trackID: trackID)
        } label: {
            Label(label, systemImage: "play.circle.fill")
        }
        .buttonStyle(.bordered)
        .tint(ConvoLabTheme.navy)
        .disabled(localURL == nil || player.isBlockedByLongFormAudio)
        .accessibilityHint(
            player.isBlockedByLongFormAudio
                ? "Pause Daily Audio before playing a study card."
                : didAttemptLoad && localURL == nil
                ? "Audio is not available offline."
                : "Plays downloaded study audio."
        )
        .task(id: "\(trackID)|autoplay:\(autoplay)") {
            didAttemptLoad = false
            localURL = nil
            let resolvedURL = await store.playableMediaURL(for: remoteURL)
            guard !Task.isCancelled else { return }
            localURL = resolvedURL
            didAttemptLoad = true
            if autoplay, let resolvedURL {
                player.play(url: resolvedURL, trackID: trackID)
            }
        }
    }
}

private struct StudyCardImage: View {
    let remoteURL: URL
    let accessibilityLabel: String
    let store: StudyStore

    @State private var image: UIImage?
    @State private var didAttemptLoad = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel(accessibilityLabel)
            } else if !didAttemptLoad {
                ProgressView()
                    .accessibilityLabel("Loading study image")
            } else {
                Label("Image unavailable offline", systemImage: "photo.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: remoteURL) {
            didAttemptLoad = false
            image = nil
            let localURL = await store.playableMediaURL(for: remoteURL)
            guard !Task.isCancelled else { return }
            image = localURL.flatMap {
                UIImage(contentsOfFile: $0.path)
            }
            didAttemptLoad = true
        }
    }
}

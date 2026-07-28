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

    @State private var showingAnswer = false
    @State private var cardStartedAt = Date.now
    @State private var submittingReviewCardIDs: Set<String> = []
    @State private var answerAudioLocalURL: URL?
    @State private var didAttemptAnswerAudioLoad = false
    @State private var didAutoplayAnswerForCardID: String?
    @State private var editingCard: StudyCard?
    @State private var undoActions: [StudyUndoAction] = []
    @State private var isUndoing = false
    @State private var undoErrorMessage: String?
    @State private var answerRestoredByUndoCardID: String?
    @State private var reviewIntervalLabels: [ReviewRating: String] = [:]
    @State private var lessonPreview = true
    @State private var lessonPreviewIndex = 0
    @State private var loadingLessons = false

    init(store: StudyStore, player: StudyAudioPlayer, mode: Mode = .reviews) {
        self.store = store
        self.player = player
        self.mode = mode
        _lessonPreview = State(initialValue: mode == .lessons)
    }

    private var card: StudyCard? { store.cards.first }
    private var remainingCount: Int {
        mode == .lessons
            ? store.cards.count
            : store.sessionCounts.failedDue + store.sessionCounts.reviewRemaining
    }

    var body: some View {
        VStack(spacing: 22) {
            ProgressView(value: store.sessionProgress)
                .tint(.green)
                .accessibilityLabel("Session progress")

            if mode == .lessons, lessonPreview {
                lessonPreviewContent
            } else if let card {
                let presentation = card.presentation
                HStack(spacing: 8) {
                    if showingAnswer,
                       StudyCardDraft.CardType(rawValue: card.cardType) != nil {
                        Button {
                            player.stop()
                            editingCard = card
                        } label: {
                            Image(systemName: "pencil")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.bordered)
                        .tint(ConvoLabTheme.navy)
                        .accessibilityLabel("Edit card")
                        .accessibilityIdentifier("StudyAnswerEditButton")
                    }
                    sessionMetric(
                        label: "Remaining",
                        value: remainingCount,
                        color: ConvoLabTheme.navy
                    )
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(remainingCount) cards remaining")

                Spacer()

                if showingAnswer {
                    answerFace(presentation.back, card: card)
                } else {
                    promptFace(presentation.front, cardID: card.id)
                }

                Spacer()

                if showingAnswer {
                    gradeButtons(card: card)
                } else {
                    Button("Show Answer") {
                        player.stop()
                        pushUndo(.reveal(cardID: card.id))
                        prepareReviewIntervalLabels(for: card)
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
            } else {
                if mode == .lessons {
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
                            Task { await store.synchronize() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ConvoLabTheme.navy)
                        .disabled(store.syncStatus == .syncing)
                    }
                } else {
                    ContentUnavailableView(
                        "Session complete",
                        systemImage: "checkmark.seal.fill",
                        description: Text("Any offline reviews are safely queued for sync.")
                    )
                }
            }
        }
        .padding()
        .paperBackground()
        .background {
            ShakeDetector(isEnabled: editingCard == nil) {
                Task { await undoLastAction() }
            }
        }
        .accessibilityAction(named: Text("Undo Last Study Action")) {
            Task { await undoLastAction() }
        }
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if mode == .lessons {
                store.beginLessonSessionPresentation()
                await loadLessonBatch()
            } else {
                store.beginSessionFailureTracking()
                try? await store.refreshSession()
            }
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
            reviewIntervalLabels = [:]
            cardStartedAt = .now
            didAutoplayAnswerForCardID = nil
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
            player.stop()
            if mode == .lessons {
                store.endLessonSessionPresentation()
            }
        }
        .sheet(item: $editingCard) { card in
            CardEditorView(
                store: store,
                player: player,
                card: card,
                serverDraft: nil
            )
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

    private func sessionMetric(label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(.caption2.bold())
                .tracking(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if block.role == .note {
                            Text("•")
                        }
                        if block.role.supportsRuby {
                            StudyRubyText(
                                block.text,
                                knownKanji: store.knownKanji,
                                pointSize: pointSize(for: block.role),
                                color: uiColor(for: block.role)
                            )
                        } else {
                            Text(block.text)
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)
                        }
                    }
                    .font(font(for: block.role))
                    .foregroundStyle(color(for: block.role))
                    .accessibilityElement(children: .combine)
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

    private func gradeButton(
        _ title: String,
        rating: ReviewRating,
        color: Color,
        card: StudyCard
    ) -> some View {
        Button {
            if mode == .lessons, rating == .again {
                player.stop()
                didAutoplayAnswerForCardID = nil
                store.retryLessonCard(card)
                showingAnswer = false
                reviewIntervalLabels = [:]
                cardStartedAt = .now
                return
            }
            guard submittingReviewCardIDs.insert(card.id).inserted else { return }
            let reviewedAt = Date.now
            if rating == .again {
                didAutoplayAnswerForCardID = nil
            }
            let duration = reviewedAt.timeIntervalSince(cardStartedAt)
            Task {
                let eventID = await store.recordReview(
                    card: card,
                    rating: rating,
                    duration: .milliseconds(Int64(duration * 1_000)),
                    reviewedAt: reviewedAt
                )
                if let eventID {
                    pushUndo(.grade(eventID: eventID, cardBefore: card))
                }
                submittingReviewCardIDs.remove(card.id)
            }
        } label: {
            VStack(spacing: 2) {
                Text(reviewIntervalLabels[rating] ?? "—")
                    .font(.caption.bold())
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .frame(maxWidth: .infinity)
        .disabled(submittingReviewCardIDs.contains(card.id) || isUndoing)
    }

    private func prepareReviewIntervalLabels(
        for card: StudyCard,
        at reviewedAt: Date = .now
    ) {
        reviewIntervalLabels = Dictionary(uniqueKeysWithValues: ReviewRating.allCases.map {
            ($0, card.reviewSchedule($0, at: reviewedAt).intervalLabel)
        })
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
            !isUndoing,
            submittingReviewCardIDs.isEmpty,
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
                prepareReviewIntervalLabels(for: cardBefore)
                showingAnswer = true
                cardStartedAt = .now
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

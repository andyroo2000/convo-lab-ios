import SwiftUI
import UIKit

struct StudySessionView: View {
    let store: StudyStore
    let player: StudyAudioPlayer

    @State private var showingAnswer = false
    @State private var cardStartedAt = Date.now
    @State private var submittingReviewCardIDs: Set<String> = []

    private var card: StudyCard? { store.cards.first }

    var body: some View {
        VStack(spacing: 22) {
            if let card {
                let presentation = card.presentation
                HStack {
                    Text(card.state.queueState.uppercased())
                        .font(.caption.bold())
                        .tracking(1.5)
                    Spacer()
                    Text("\(store.cards.count) remaining")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                Spacer()

                if showingAnswer {
                    answerFace(presentation.back, cardID: card.id)
                } else {
                    promptFace(presentation.front, cardID: card.id)
                }

                Spacer()

                if showingAnswer {
                    gradeButtons(card: card)
                } else {
                    Button("Show Answer") {
                        player.stop()
                        withAnimation(.snappy) {
                            showingAnswer = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ConvoLabTheme.navy)
                    .controlSize(.large)
                }
            } else {
                ContentUnavailableView(
                    "Session complete",
                    systemImage: "checkmark.seal.fill",
                    description: Text("Any offline reviews are safely queued for sync.")
                )
            }
        }
        .padding()
        .paperBackground()
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: card?.id) {
            player.stop()
            showingAnswer = false
            cardStartedAt = .now
        }
        .onDisappear {
            player.stop()
        }
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
                    store: store,
                    player: player
                )
            }
            if let heading = face.heading {
                Text(heading)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
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
    private func answerFace(_ face: StudyCardPresentation.Face, cardID: String) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                if let heading = face.heading {
                    Text(heading)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }

                if let audioURL = face.audioURL {
                    StudyCardAudioButton(
                        remoteURL: audioURL,
                        trackID: "study-answer-\(cardID)",
                        label: "Play answer audio",
                        store: store,
                        player: player
                    )
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
                        Text(block.text)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    .font(font(for: block.role))
                    .foregroundStyle(color(for: block.role))
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func font(for role: StudyCardPresentation.TextRole) -> Font {
        switch role {
        case .restoredText, .meaning: .title2
        case .sentenceJapanese: .title3
        case .sentenceEnglish, .note: .body
        }
    }

    private func color(for role: StudyCardPresentation.TextRole) -> Color {
        switch role {
        case .restoredText, .sentenceJapanese: .primary
        case .meaning: ConvoLabTheme.navy
        case .sentenceEnglish, .note: .secondary
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
            guard submittingReviewCardIDs.insert(card.id).inserted else { return }
            let duration = Date.now.timeIntervalSince(cardStartedAt)
            Task {
                await store.recordReview(
                    card: card,
                    rating: rating,
                    duration: .milliseconds(Int64(duration * 1_000))
                )
                submittingReviewCardIDs.remove(card.id)
            }
        } label: {
            VStack(spacing: 2) {
                Text(rating.nextIntervalLabel)
                    .font(.caption.bold())
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .frame(maxWidth: .infinity)
        .disabled(submittingReviewCardIDs.contains(card.id))
    }
}

private struct StudyCardAudioButton: View {
    let remoteURL: URL
    let trackID: String
    let label: String
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
        .task(id: remoteURL) {
            didAttemptLoad = false
            localURL = nil
            let resolvedURL = await store.playableMediaURL(for: remoteURL)
            guard !Task.isCancelled else { return }
            localURL = resolvedURL
            didAttemptLoad = true
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

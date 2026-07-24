import SwiftUI

struct StudySessionView: View {
    let store: StudyStore

    @State private var showingAnswer = false
    @State private var cardStartedAt = Date.now

    private var card: StudyCard? { store.cards.first }

    var body: some View {
        VStack(spacing: 22) {
            if let card {
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

                Text(card.promptText)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)

                if let promptHint = card.promptHint, !showingAnswer {
                    Text(promptHint)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                if showingAnswer {
                    Divider()
                    Text(card.answerText)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ConvoLabTheme.navy)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    if let answerDetailText = card.answerDetailText {
                        Text(answerDetailText)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }

                Spacer()

                if showingAnswer {
                    gradeButtons(card: card)
                } else {
                    Button("Show Answer") {
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
            showingAnswer = false
            cardStartedAt = .now
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
            let duration = Date.now.timeIntervalSince(cardStartedAt)
            Task {
                await store.recordReview(
                    card: card,
                    rating: rating,
                    duration: .milliseconds(Int64(duration * 1_000))
                )
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
    }
}

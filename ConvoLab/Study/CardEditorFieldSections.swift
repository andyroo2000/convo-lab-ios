import SwiftUI

struct CardEditorStandardFields: View {
    @Binding var draft: StudyCardDraft
    let creationKind: StudyCardCreationKind
    let isNewCard: Bool

    var body: some View {
        Group {
            if draft.isAudioLedPrompt {
                Section("Prompt") {
                    Label(
                        creationKind == .audioRecognition && isNewCard
                            ? "This card uses generated audio as the prompt."
                            : "This card uses its existing audio or image as the prompt.",
                        systemImage: "play.rectangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } else {
                Section("Prompt") {
                    TextField("Japanese prompt", text: $draft.cueText, axis: .vertical)
                    TextField(
                        "Prompt reading (optional)",
                        text: $draft.cueReading,
                        axis: .vertical
                    )
                    TextField(
                        "Prompt hint (optional)",
                        text: $draft.cueMeaning,
                        axis: .vertical
                    )
                }
            }
            Section("Answer") {
                TextField(
                    "Japanese answer",
                    text: $draft.answerExpression,
                    axis: .vertical
                )
                TextField(
                    "Answer reading (optional)",
                    text: $draft.answerReading,
                    axis: .vertical
                )
                TextField(
                    "Meaning (optional)",
                    text: $draft.answerMeaning,
                    axis: .vertical
                )
                .lineLimit(2...6)
                .accessibilityIdentifier("card-editor-answer-meaning")
                TextField(
                    "Japanese example (optional)",
                    text: $draft.sentenceJapanese,
                    axis: .vertical
                )
                .lineLimit(2...6)
                TextField(
                    "English example (optional)",
                    text: $draft.sentenceEnglish,
                    axis: .vertical
                )
                .lineLimit(2...6)
            }
        }
    }
}

struct CardEditorClozeFields: View {
    @Binding var draft: StudyCardDraft

    var body: some View {
        Group {
            Section("Prompt") {
                TextField("Cloze text", text: $draft.cueText, axis: .vertical)
                    .lineLimit(2...6)
                Text("Use Anki-style markup, for example: 毎日{{c1::勉強する}}。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !draft.cueText.isEmpty, !draft.hasCanonicalClozeMarkup {
                    Text("Add a cloze marker such as {{c1::answer}} before saving.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                TextField("Hint (optional)", text: $draft.cueMeaning, axis: .vertical)
            }
            Section("Answer") {
                TextField(
                    "Restored sentence",
                    text: $draft.answerExpression,
                    axis: .vertical
                )
                .lineLimit(2...6)
                TextField(
                    "Sentence with furigana (optional)",
                    text: $draft.answerReading,
                    axis: .vertical
                )
                .lineLimit(2...6)
                TextField(
                    "Meaning (optional)",
                    text: $draft.answerMeaning,
                    axis: .vertical
                )
                .lineLimit(2...6)
                .accessibilityIdentifier("card-editor-answer-meaning")
            }
        }
    }
}

import SwiftUI

struct StudySessionAnswer: View {
    let face: StudyCardPresentation.Face
    let store: StudyStore

    var body: some View {
        VStack(spacing: 24) {
            if let heading = face.heading {
                StudyReadingHeading(text: heading, knownKanji: store.knownKanji)
            }
            if let meaning = standaloneMeaning {
                Text(meaning)
                    .font(font(for: .meaning))
                    .foregroundStyle(color(for: .meaning))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            } else if face.imageURL != nil || !face.textBlocks.isEmpty {
                answerDetails
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var standaloneMeaning: String? {
        guard face.imageURL == nil, face.textBlocks.count == 1, let block = face.textBlocks.first,
              block.role == .meaning, let heading = face.heading,
              StudyReadingSize(heading).alignment == .center else { return nil }
        return block.text
    }

    private var answerDetails: some View {
        VStack(spacing: 23) {
            if let imageURL = face.imageURL {
                StudyCardImage(
                    remoteURL: imageURL,
                    accessibilityLabel: face.textBlocks.first { $0.role == .meaning }?.text ?? "Answer image",
                    store: store
                )
            }
            ForEach(face.textBlocks) { block in answerTextBlock(block) }
        }
        .padding(.leading, 16)
        .overlay(alignment: .leading) {
            Rectangle().fill(StudyWashiStyle.green.opacity(0.4)).frame(width: 3)
        }
    }

    @ViewBuilder
    private func answerTextBlock(_ block: StudyCardPresentation.TextBlock) -> some View {
        let text = block.text

        Group {
            if block.role.supportsRuby {
                StudyRubyText(
                    text,
                    knownKanji: store.knownKanji,
                    pointSize: pointSize(for: block.role),
                    color: UIColor(color(for: block.role)),
                    alignment: .left,
                    font: block.role == .note ? StudyWashiStyle.noteFont : nil,
                    readingColor: UIColor(StudyWashiStyle.secondaryInk)
                )
                .font(font(for: block.role))
                .foregroundStyle(color(for: block.role))
                .accessibilityElement(children: .combine)
            } else {
                Text(text)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .font(font(for: block.role))
                    .foregroundStyle(color(for: block.role))
                    .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func font(for role: StudyCardPresentation.TextRole) -> Font {
        switch role {
        case .restoredText, .meaning: .custom("CrimsonPro-Regular", size: 26, relativeTo: .title2)
        case .sentenceJapanese: .title3
        case .sentenceEnglish: .custom("CrimsonPro-Regular", size: 20, relativeTo: .body)
        case .note: .custom("CrimsonPro-Regular", size: 17, relativeTo: .body).italic()
        }
    }

    private func pointSize(for role: StudyCardPresentation.TextRole) -> CGFloat {
        switch role {
        case .restoredText, .meaning: 26
        case .sentenceJapanese: 20
        case .sentenceEnglish, .note: 17
        }
    }

    private func color(for role: StudyCardPresentation.TextRole) -> Color {
        switch role {
        case .restoredText, .sentenceJapanese, .meaning, .sentenceEnglish: StudyWashiStyle.ink
        case .note: StudyWashiStyle.secondaryInk
        }
    }
}

private extension StudyCardPresentation.TextRole {
    var supportsRuby: Bool {
        switch self {
        case .restoredText, .sentenceJapanese, .note: true
        case .meaning, .sentenceEnglish: false
        }
    }
}

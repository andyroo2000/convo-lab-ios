import Foundation

struct StudyCardDraft: Equatable, Sendable {
    enum CardType: String, CaseIterable, Identifiable, Sendable {
        case recognition
        case production
        case cloze

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recognition: "Recognition"
            case .production: "Production"
            case .cloze: "Cloze"
            }
        }
    }

    var cardType: CardType
    var cueText: String
    var cueReading: String
    var cueMeaning: String
    var answerExpression: String
    var answerReading: String
    var answerMeaning: String
    var sentenceJapanese: String
    var sentenceEnglish: String
    var notes: String
    var isMediaLedPrompt: Bool
    var isAudioLedPrompt: Bool

    init(cardType: CardType = .recognition) {
        self.cardType = cardType
        cueText = ""
        cueReading = ""
        cueMeaning = ""
        answerExpression = ""
        answerReading = ""
        answerMeaning = ""
        sentenceJapanese = ""
        sentenceEnglish = ""
        notes = ""
        isMediaLedPrompt = false
        isAudioLedPrompt = false
    }

    init(card: StudyCard) {
        cardType = CardType(rawValue: card.cardType) ?? .recognition
        isMediaLedPrompt = cardType != .cloze
            && card.prompt.firstNonEmptyString(for: ["cueText"]) == nil
            && !card.prompt.mediaURLs.isEmpty
        isAudioLedPrompt = cardType == .recognition
            && card.prompt.firstNonEmptyString(for: ["cueText"]) == nil
            && card.prompt.firstNonEmptyString(for: ["cueMeaning"]) == nil
            && card.prompt["cueAudio"]?.mediaURLs.isEmpty == false
        if cardType == .cloze {
            cueText = card.prompt.firstNonEmptyString(for: ["clozeText"]) ?? ""
            cueReading = ""
            cueMeaning = card.prompt.firstNonEmptyString(
                for: ["clozeHint", "clozeResolvedHint"]
            ) ?? ""
            answerExpression = card.answer.firstNonEmptyString(for: ["restoredText"]) ?? ""
            answerReading = card.answer.firstNonEmptyString(for: ["restoredTextReading"]) ?? ""
            answerMeaning = card.answer.firstNonEmptyString(for: ["meaning"]) ?? ""
            sentenceJapanese = ""
            sentenceEnglish = ""
        } else {
            cueText = card.prompt.firstNonEmptyString(for: ["cueText"]) ?? ""
            cueReading = card.prompt.firstNonEmptyString(for: ["cueReading"]) ?? ""
            cueMeaning = card.prompt.firstNonEmptyString(for: ["cueMeaning"]) ?? ""
            answerExpression = card.answer.firstNonEmptyString(for: ["expression"]) ?? ""
            answerReading = card.answer.firstNonEmptyString(for: ["expressionReading"]) ?? ""
            answerMeaning = card.answer.firstNonEmptyString(for: ["meaning"]) ?? ""
            sentenceJapanese = card.answer.firstNonEmptyString(for: ["sentenceJp"]) ?? ""
            sentenceEnglish = card.answer.firstNonEmptyString(for: ["sentenceEn"]) ?? ""
        }
        notes = card.answer.firstNonEmptyString(for: ["notes"]) ?? ""
    }

    var isValid: Bool {
        switch cardType {
        case .cloze:
            !cueText.trimmed.isEmpty && !answerExpression.trimmed.isEmpty
        case .recognition, .production:
            (isMediaLedPrompt || !cueText.trimmed.isEmpty)
                && !answerExpression.trimmed.isEmpty
        }
    }

    func prompt(merging existing: JSONValue = .object([:])) -> JSONValue {
        switch cardType {
        case .cloze:
            existing.replacingObjectValues([
                "clozeText": .string(cueText.trimmed),
                "clozeHint": cueMeaning.optionalJSONText(
                    preservingNonString: existing["clozeHint"]
                ),
            ])
        case .recognition, .production:
            existing.replacingObjectValues([
                "cueText": isAudioLedPrompt ? .null : .string(cueText.trimmed),
                "cueReading": isAudioLedPrompt
                    ? .null
                    : cueReading.optionalJSONText(
                        preservingNonString: existing["cueReading"]
                    ),
                "cueMeaning": isAudioLedPrompt
                    ? .null
                    : cueMeaning.optionalJSONText(
                        preservingNonString: existing["cueMeaning"]
                    ),
            ])
        }
    }

    func answer(merging existing: JSONValue = .object([:])) -> JSONValue {
        switch cardType {
        case .cloze:
            existing.replacingObjectValues([
                "restoredText": .string(answerExpression.trimmed),
                "restoredTextReading": answerReading.optionalJSONText(
                    preservingNonString: existing["restoredTextReading"]
                ),
                "meaning": answerMeaning.optionalJSONText(
                    preservingNonString: existing["meaning"]
                ),
                "notes": notes.optionalJSONText(
                    preservingNonString: existing["notes"]
                ),
            ])
        case .recognition, .production:
            existing.replacingObjectValues([
                "expression": .string(answerExpression.trimmed),
                "expressionReading": answerReading.optionalJSONText(
                    preservingNonString: existing["expressionReading"]
                ),
                "meaning": answerMeaning.optionalJSONText(
                    preservingNonString: existing["meaning"]
                ),
                "sentenceJp": sentenceJapanese.optionalJSONText(
                    preservingNonString: existing["sentenceJp"]
                ),
                "sentenceEn": sentenceEnglish.optionalJSONText(
                    preservingNonString: existing["sentenceEn"]
                ),
                "notes": notes.optionalJSONText(
                    preservingNonString: existing["notes"]
                ),
            ])
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func optionalJSONText(preservingNonString existing: JSONValue? = nil) -> JSONValue {
        let value = trimmed
        if !value.isEmpty {
            return .string(value)
        }
        if let existing, existing != .null, existing.stringValue == nil {
            return existing
        }
        return .null
    }
}

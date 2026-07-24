import Foundation

struct StudyCardDraft: Equatable, Sendable {
    enum ImagePlacement: String, CaseIterable, Identifiable, Sendable {
        case none
        case prompt
        case answer
        case both

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: "No image"
            case .prompt: "Front"
            case .answer: "Back"
            case .both: "Front and back"
            }
        }

        var includesPrompt: Bool { self == .prompt || self == .both }
        var includesAnswer: Bool { self == .answer || self == .both }
    }

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
    var answerAudioVoiceId: String
    var answerAudioTextOverride: String
    var imagePlacement: ImagePlacement {
        didSet {
            if imagePlacement != oldValue {
                preservesIndependentFaceImages = false
            }
        }
    }
    var imagePrompt: String
    var currentImage: JSONValue? {
        didSet {
            if currentImage != oldValue {
                preservesIndependentFaceImages = false
            }
        }
    }
    var notes: String
    var isMediaLedPrompt: Bool
    var isAudioLedPrompt: Bool
    private var originalClozeHint: String?
    private var preservesIndependentFaceImages: Bool

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
        answerAudioVoiceId = StudyAnswerVoice.defaultVoice.id
        answerAudioTextOverride = ""
        preservesIndependentFaceImages = false
        imagePlacement = .none
        imagePrompt = ""
        currentImage = nil
        notes = ""
        isMediaLedPrompt = false
        isAudioLedPrompt = false
        originalClozeHint = nil
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
                for: ["clozeResolvedHint", "clozeHint"]
            ) ?? ""
            originalClozeHint = cueMeaning
            answerExpression = card.answer.firstNonEmptyString(for: ["restoredText"]) ?? ""
            answerReading = card.answer.firstNonEmptyString(for: ["restoredTextReading"]) ?? ""
            answerMeaning = card.answer.firstNonEmptyString(for: ["meaning"]) ?? ""
            sentenceJapanese = ""
            sentenceEnglish = ""
        } else {
            originalClozeHint = nil
            cueText = card.prompt.firstNonEmptyString(for: ["cueText"]) ?? ""
            cueReading = card.prompt.firstNonEmptyString(for: ["cueReading"]) ?? ""
            cueMeaning = card.prompt.firstNonEmptyString(for: ["cueMeaning"]) ?? ""
            answerExpression = card.answer.firstNonEmptyString(for: ["expression"]) ?? ""
            answerReading = card.answer.firstNonEmptyString(for: ["expressionReading"]) ?? ""
            answerMeaning = card.answer.firstNonEmptyString(for: ["meaning"]) ?? ""
            sentenceJapanese = card.answer.firstNonEmptyString(for: ["sentenceJp"]) ?? ""
            sentenceEnglish = card.answer.firstNonEmptyString(for: ["sentenceEn"]) ?? ""
        }
        answerAudioVoiceId = card.answer.firstNonEmptyString(
            for: ["answerAudioVoiceId"]
        ) ?? StudyAnswerVoice.defaultVoice.id
        answerAudioTextOverride = card.answer.firstNonEmptyString(
            for: ["answerAudioTextOverride"]
        ) ?? ""
        preservesIndependentFaceImages = false
        let promptImage = card.prompt["cueImage"]
        let answerImage = card.answer["answerImage"]
        currentImage = promptImage?.mediaURLs.isEmpty == false ? promptImage : answerImage
        imagePlacement = if
            promptImage?.mediaURLs.isEmpty == false,
            answerImage?.mediaURLs.isEmpty == false
        {
            .both
        } else if promptImage?.mediaURLs.isEmpty == false {
            .prompt
        } else if answerImage?.mediaURLs.isEmpty == false {
            .answer
        } else {
            // Match the desktop editor's default role for cards without an image.
            .answer
        }
        preservesIndependentFaceImages =
            promptImage?.mediaURLs.isEmpty == false
            && answerImage?.mediaURLs.isEmpty == false
            && promptImage != answerImage
        let imageSubject = card.answer.firstNonEmptyString(
            for: ["expression", "restoredText"]
        ) ?? card.prompt.firstNonEmptyString(for: ["cueText"])
            ?? card.answer.firstNonEmptyString(for: ["meaning"])
            ?? "this study card"
        let imageMeaning = card.answer.firstNonEmptyString(for: ["meaning"])
            .map { " (\($0))" } ?? ""
        imagePrompt = "A clear natural real-world image representing \(imageSubject)\(imageMeaning)."
        notes = card.answer.firstNonEmptyString(for: ["notes"]) ?? ""
    }

    var isValid: Bool {
        switch cardType {
        case .cloze:
            hasCanonicalClozeMarkup && !answerExpression.trimmed.isEmpty
        case .recognition, .production:
            (isMediaLedPrompt || !cueText.trimmed.isEmpty)
                && !answerExpression.trimmed.isEmpty
        }
    }

    var hasCanonicalClozeMarkup: Bool {
        cueText.range(of: #"(?s)\{\{c\d+::.+?\}\}"#, options: .regularExpression) != nil
    }

    func prompt(merging existing: JSONValue = .object([:])) -> JSONValue {
        let textPayload: JSONValue
        switch cardType {
        case .cloze:
            var replacements: [String: JSONValue] = [
                "clozeText": .string(cueText.trimmed),
            ]
            if let originalClozeHint {
                if cueMeaning.trimmed != originalClozeHint.trimmed {
                    replacements["clozeHint"] = cueMeaning.optionalJSONText(
                        preservingNonString: existing["clozeHint"]
                    )
                    // clozeResolvedHint wins during presentation. Once the user
                    // explicitly edits the displayed hint, clear that derived value
                    // so the new manual hint is visible immediately.
                    replacements["clozeResolvedHint"] = .null
                }
            } else if !cueMeaning.trimmed.isEmpty {
                replacements["clozeHint"] = .string(cueMeaning.trimmed)
            }
            textPayload = existing.replacingObjectValues(replacements)
        case .recognition, .production:
            textPayload = existing.replacingObjectValues([
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
        let cueImage = preservesIndependentFaceImages
            ? existing["cueImage"] ?? .null
            : imagePlacement.includesPrompt ? currentImage ?? .null : .null
        return textPayload.replacingObjectValues(["cueImage": cueImage])
    }

    func answer(merging existing: JSONValue = .object([:])) -> JSONValue {
        let textPayload = switch cardType {
        case .cloze:
            existing.replacingObjectValues([
                "restoredText": .string(answerExpression.trimmed),
                "restoredTextReading": answerReading.optionalJSONText(
                    preservingNonString: existing["restoredTextReading"]
                ),
                "meaning": answerMeaning.optionalJSONText(
                    preservingNonString: existing["meaning"]
                ),
                "answerAudioVoiceId": answerAudioVoiceId.optionalJSONText(
                    preservingNonString: existing["answerAudioVoiceId"]
                ),
                "answerAudioTextOverride": answerAudioTextOverride.optionalJSONText(
                    preservingNonString: existing["answerAudioTextOverride"]
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
                "answerAudioVoiceId": answerAudioVoiceId.optionalJSONText(
                    preservingNonString: existing["answerAudioVoiceId"]
                ),
                "answerAudioTextOverride": answerAudioTextOverride.optionalJSONText(
                    preservingNonString: existing["answerAudioTextOverride"]
                ),
                "notes": notes.optionalJSONText(
                    preservingNonString: existing["notes"]
                ),
            ])
        }
        let answerImage = preservesIndependentFaceImages
            ? existing["answerImage"] ?? .null
            : imagePlacement.includesAnswer ? currentImage ?? .null : .null
        return textPayload.replacingObjectValues(["answerImage": answerImage])
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

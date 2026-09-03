import Foundation

struct StudyCardDraft: Equatable, Sendable {
    private struct ImportedTextContent {
        let cueText: String
        let cueReading: String
        let cueMeaning: String
        let answerExpression: String
        let answerReading: String
        let answerMeaning: String
        let sentenceJapanese: String
        let sentenceEnglish: String
        let originalClozeHint: String?
    }

    private struct ImportedImageContent {
        let promptImage: JSONValue?
        let answerImage: JSONValue?
        let currentImage: JSONValue?
        let placement: ImagePlacement
        let preservesIndependentFaces: Bool
        let generationPrompt: String
    }

    enum ImagePlacement: String, Codable, CaseIterable, Identifiable, Sendable {
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

    enum CardType: String, Codable, CaseIterable, Identifiable, Sendable {
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
                if hasIndependentFaceImages {
                    currentImage = switch imagePlacement {
                    case .answer:
                        originalAnswerImage ?? originalPromptImage
                    case .none, .prompt, .both:
                        originalPromptImage ?? originalAnswerImage
                    }
                }
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
    private var originalPromptImage: JSONValue?
    private var originalAnswerImage: JSONValue?

    init(
        cardType: CardType = .recognition,
        defaultAnswerAudioVoiceID: String = StudyAnswerVoice.defaultVoice.id
    ) {
        self.cardType = cardType
        cueText = ""
        cueReading = ""
        cueMeaning = ""
        answerExpression = ""
        answerReading = ""
        answerMeaning = ""
        sentenceJapanese = ""
        sentenceEnglish = ""
        answerAudioVoiceId = defaultAnswerAudioVoiceID
        answerAudioTextOverride = ""
        preservesIndependentFaceImages = false
        originalPromptImage = nil
        originalAnswerImage = nil
        imagePlacement = .none
        imagePrompt = ""
        currentImage = nil
        notes = ""
        isMediaLedPrompt = false
        isAudioLedPrompt = false
        originalClozeHint = nil
    }

    init(
        card: StudyCard,
        defaultAnswerAudioVoiceID: String = StudyAnswerVoice.defaultVoice.id
    ) {
        cardType = CardType(rawValue: card.cardType) ?? .recognition
        isMediaLedPrompt = Self.isMediaLedPrompt(card, cardType: cardType)
        isAudioLedPrompt = Self.isAudioLedPrompt(card, cardType: cardType)
        let textContent = Self.importedTextContent(from: card, cardType: cardType)
        cueText = textContent.cueText
        cueReading = textContent.cueReading
        cueMeaning = textContent.cueMeaning
        answerExpression = textContent.answerExpression
        answerReading = textContent.answerReading
        answerMeaning = textContent.answerMeaning
        sentenceJapanese = textContent.sentenceJapanese
        sentenceEnglish = textContent.sentenceEnglish
        originalClozeHint = textContent.originalClozeHint
        answerAudioVoiceId = card.answer.editorText(
            ["answerAudioVoiceId"],
            fallback: defaultAnswerAudioVoiceID
        )
        answerAudioTextOverride = card.answer.editorText(["answerAudioTextOverride"])
        let imageContent = Self.importedImageContent(from: card)
        originalPromptImage = imageContent.promptImage
        originalAnswerImage = imageContent.answerImage
        currentImage = imageContent.currentImage
        imagePlacement = imageContent.placement
        preservesIndependentFaceImages = imageContent.preservesIndependentFaces
        imagePrompt = imageContent.generationPrompt
        notes = card.answer.editorText(["notes"])
    }

    private static func isMediaLedPrompt(
        _ card: StudyCard,
        cardType: CardType
    ) -> Bool {
        cardType != .cloze
            && card.prompt.firstNonEmptyString(for: ["cueText"]) == nil
            && !card.prompt.mediaURLs.isEmpty
    }

    private static func isAudioLedPrompt(
        _ card: StudyCard,
        cardType: CardType
    ) -> Bool {
        cardType == .recognition
            && card.prompt.firstNonEmptyString(for: ["cueText"]) == nil
            && card.prompt.firstNonEmptyString(for: ["cueMeaning"]) == nil
            && card.prompt["cueAudio"]?.mediaURLs.isEmpty == false
    }

    private static func importedTextContent(
        from card: StudyCard,
        cardType: CardType
    ) -> ImportedTextContent {
        if cardType == .cloze {
            let cueMeaning = card.prompt.editorText(
                ["clozeResolvedHint", "clozeHint"]
            )
            return ImportedTextContent(
                cueText: card.prompt.editorText(["clozeText"]),
                cueReading: "",
                cueMeaning: cueMeaning,
                answerExpression: card.answer.editorText(["restoredText"]),
                answerReading: card.answer.editorText(["restoredTextReading"]),
                answerMeaning: card.answer.editorText(["meaning"]),
                sentenceJapanese: "",
                sentenceEnglish: "",
                originalClozeHint: cueMeaning
            )
        }
        return ImportedTextContent(
            cueText: card.prompt.editorText(["cueText"]),
            cueReading: card.prompt.editorText(["cueReading"]),
            cueMeaning: card.prompt.editorText(["cueMeaning"]),
            answerExpression: card.answer.editorText(["expression"]),
            answerReading: card.answer.editorText(["expressionReading"]),
            answerMeaning: card.answer.editorText(["meaning"]),
            sentenceJapanese: card.answer.editorText(["sentenceJp"]),
            sentenceEnglish: card.answer.editorText(["sentenceEn"]),
            originalClozeHint: nil
        )
    }

    private static func importedImageContent(
        from card: StudyCard
    ) -> ImportedImageContent {
        let promptImage = card.prompt["cueImage"]
        let answerImage = card.answer["answerImage"]
        let hasPromptImage = promptImage?.mediaURLs.isEmpty == false
        let hasAnswerImage = answerImage?.mediaURLs.isEmpty == false
        return ImportedImageContent(
            promptImage: promptImage,
            answerImage: answerImage,
            currentImage: hasPromptImage ? promptImage : answerImage,
            placement: imagePlacement(
                hasPromptImage: hasPromptImage,
                hasAnswerImage: hasAnswerImage
            ),
            preservesIndependentFaces: hasPromptImage
                && hasAnswerImage
                && promptImage != answerImage,
            generationPrompt: imageGenerationPrompt(for: card)
        )
    }

    private static func imagePlacement(
        hasPromptImage: Bool,
        hasAnswerImage: Bool
    ) -> ImagePlacement {
        if hasPromptImage, hasAnswerImage {
            return .both
        }
        if hasPromptImage {
            return .prompt
        }
        if hasAnswerImage {
            return .answer
        }
        // Match the desktop editor's default role for cards without an image.
        return .answer
    }

    private static func imageGenerationPrompt(for card: StudyCard) -> String {
        let imageSubject = [
            card.answer.firstNonEmptyString(for: ["expression", "restoredText"]),
            card.prompt.firstNonEmptyString(for: ["cueText"]),
            card.answer.firstNonEmptyString(for: ["meaning"]),
        ].compactMap { $0 }.first ?? "this study card"
        let imageMeaning = card.answer.firstNonEmptyString(for: ["meaning"])
            .map { " (\($0))" } ?? ""
        return "A clear natural real-world image representing \(imageSubject)\(imageMeaning)."
    }

    init(
        manualDraft: StudyManualCardDraft,
        defaultAnswerAudioVoiceID: String = StudyAnswerVoice.defaultVoice.id
    ) {
        var prompt = manualDraft.prompt
        var answer = manualDraft.answer
        if let previewAudio = manualDraft.previewAudio {
            if manualDraft.previewAudioRole == "prompt" {
                prompt = prompt.replacingObjectValues(["cueAudio": previewAudio])
                answer = answer.replacingObjectValues(["answerAudio": previewAudio])
            } else if manualDraft.previewAudioRole == "answer" {
                answer = answer.replacingObjectValues(["answerAudio": previewAudio])
            }
        }
        if let previewImage = manualDraft.previewImage {
            prompt = prompt.replacingObjectValues([
                "cueImage": manualDraft.imagePlacement.includesPrompt ? previewImage : .null,
            ])
            answer = answer.replacingObjectValues([
                "answerImage": manualDraft.imagePlacement.includesAnswer ? previewImage : .null,
            ])
        }
        self.init(
            card: StudyCard(
                id: manualDraft.id,
                noteId: nil,
                cardType: manualDraft.cardType,
                prompt: prompt,
                answer: answer,
                state: .init(
                    dueAt: nil,
                    introducedAt: nil,
                    failedAt: nil,
                    queueState: "new",
                    scheduler: nil,
                    source: .object([:])
                ),
                answerAudioSource: manualDraft.previewAudio == nil ? "missing" : "generated",
                createdAt: manualDraft.createdAt,
                updatedAt: manualDraft.updatedAt
            ),
            defaultAnswerAudioVoiceID: defaultAnswerAudioVoiceID
        )
        imagePrompt = manualDraft.imagePrompt ?? ""
        imagePlacement = manualDraft.imagePlacement
        if manualDraft.creationKind == .audioRecognition {
            isAudioLedPrompt = true
            isMediaLedPrompt = true
        } else if manualDraft.creationKind == .productionImage {
            isMediaLedPrompt = true
        }
    }

    var hasIndependentFaceImages: Bool {
        guard
            let originalPromptImage,
            let originalAnswerImage,
            !originalPromptImage.mediaURLs.isEmpty,
            !originalAnswerImage.mediaURLs.isEmpty
        else {
            return false
        }
        return originalPromptImage != originalAnswerImage
    }

    var isReplacingIndependentFaceImages: Bool {
        hasIndependentFaceImages && !preservesIndependentFaceImages
    }

    mutating func reconcileImages(
        promptImage: JSONValue?,
        answerImage: JSONValue?
    ) {
        let nextPromptImage = promptImage?.mediaURLs.isEmpty == false ? promptImage : nil
        let nextAnswerImage = answerImage?.mediaURLs.isEmpty == false ? answerImage : nil
        preservesIndependentFaceImages = false
        originalPromptImage = nextPromptImage
        originalAnswerImage = nextAnswerImage
        currentImage = nextPromptImage ?? nextAnswerImage
        imagePlacement = if nextPromptImage != nil, nextAnswerImage != nil {
            .both
        } else if nextPromptImage != nil {
            .prompt
        } else if nextAnswerImage != nil {
            .answer
        } else {
            .none
        }
        preservesIndependentFaceImages =
            nextPromptImage != nil
            && nextAnswerImage != nil
            && nextPromptImage != nextAnswerImage
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

    func isValid(for creationKind: StudyCardCreationKind) -> Bool {
        isValid
            && (
                creationKind != .productionImage
                    || !imagePrompt.trimmed.isEmpty
            )
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

private extension JSONValue {
    func editorText(_ keys: [String], fallback: String = "") -> String {
        firstNonEmptyString(for: keys) ?? fallback
    }
}

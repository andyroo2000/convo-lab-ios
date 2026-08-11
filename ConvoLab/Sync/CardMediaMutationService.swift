import Foundation

struct CardAnswerAudioRegenerationResult {
    let card: StudyCard
    let localURL: URL
}

struct CardImageMutationResult {
    let card: StudyCard
    let localURL: URL
}

struct MissingGeneratedCardAudioError: LocalizedError {
    var errorDescription: String? {
        "The server regenerated this card without returning playable audio."
    }
}

struct MissingGeneratedCardImageError: LocalizedError {
    var errorDescription: String? {
        "The server regenerated this card without returning a usable image."
    }
}

struct MismatchedGeneratedCardImagesError: LocalizedError {
    var errorDescription: String? {
        "The server returned different front and back images for a shared-image request."
    }
}

struct InvalidCardImagePromptError: LocalizedError {
    var errorDescription: String? {
        "Enter a non-empty image prompt no longer than 1,000 characters."
    }
}

struct InvalidCardImagePlacementError: LocalizedError {
    var errorDescription: String? {
        "Choose Front, Back, or Front and back before regenerating an image."
    }
}

final class CardMediaMutationService {
    private let api: APIClient
    private let mediaCache: MediaCache
    private var activeUserID: Int?
    private var generation = 0

    init(api: APIClient, mediaCache: MediaCache) {
        self.api = api
        self.mediaCache = mediaCache
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        generation += 1
        activeUserID = userID
    }

    func deactivate() {
        generation += 1
        activeUserID = nil
    }

    func regenerateAnswerAudio(
        currentCard: StudyCard,
        voiceID: String,
        textOverride: String,
        latestCard: @escaping () throws -> StudyCard,
        hasPendingWrite: @escaping (String) throws -> Bool,
        onReconciled: @escaping (StudyCard, Bool, Date) throws -> Void
    ) async throws -> CardAnswerAudioRegenerationResult {
        let operation = try activeOperation()
        let request = RegenerateAnswerAudioRequest(
            answerAudioVoiceId: voiceID.nilIfTrimmedEmpty,
            answerAudioTextOverride: textOverride.nilIfTrimmedEmpty
        )
        // learning-os compatibility endpoint returns the card directly, without
        // the data envelope used by newer API endpoints.
        let serverCard: StudyCard = try await api.request(
            "/api/study/cards/\(currentCard.reviewCardID)/regenerate-answer-audio",
            method: "POST",
            body: request,
            timeout: 180
        )
        try ensureActive(operation)
        guard
            let generatedAudio = serverCard.answer["answerAudio"],
            let remoteURL = serverCard.audioURL
        else {
            throw MissingGeneratedCardAudioError()
        }
        let localURL = try await mediaCache.refresh(remoteURL, category: "active-study")
        try ensureActive(operation)

        // Once the server and cache have changed, always reconcile local card
        // metadata even if the editor that initiated the request was dismissed.
        let latest = try latestCard()
        let pendingWrite = try hasPendingWrite(latest.id)
        let serverUpdatedAt = max(latest.updatedAt, serverCard.updatedAt)
        let updated = StudyCardEditorProjection.reconcilingMedia(
            latest: latest,
            serverCard: serverCard,
            prompt: latest.prompt,
            answer: latest.answer.replacingObjectValues([
                "answerAudio": generatedAudio,
                "answerAudioVoiceId": serverCard.answer["answerAudioVoiceId"]
                    ?? request.answerAudioVoiceId.map(JSONValue.string)
                    ?? .null,
                "answerAudioTextOverride": serverCard.answer["answerAudioTextOverride"]
                    ?? request.answerAudioTextOverride.map(JSONValue.string)
                    ?? .null,
            ]),
            answerAudioSource: serverCard.answerAudioSource ?? latest.answerAudioSource,
            updatedAt: serverUpdatedAt
        )
        try ensureActive(operation)
        try onReconciled(updated, pendingWrite, serverUpdatedAt)
        return CardAnswerAudioRegenerationResult(card: updated, localURL: localURL)
    }

    func regenerateImage(
        currentCard: StudyCard,
        prompt: String,
        placement: StudyCardDraft.ImagePlacement,
        latestCard: @escaping () throws -> StudyCard,
        hasPendingWrite: @escaping (String) throws -> Bool,
        onReconciled: @escaping (StudyCard, Bool, Date) throws -> Void
    ) async throws -> CardImageMutationResult {
        let imagePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !imagePrompt.isEmpty, imagePrompt.count <= 1_000 else {
            throw InvalidCardImagePromptError()
        }
        guard placement != .none else { throw InvalidCardImagePlacementError() }
        let operation = try activeOperation()
        // learning-os compatibility endpoint returns the card directly.
        let serverCard: StudyCard = try await api.request(
            "/api/study/cards/\(currentCard.reviewCardID)/regenerate-image",
            method: "POST",
            body: RegenerateImageRequest(
                imagePrompt: imagePrompt,
                imageRole: placement.rawValue
            ),
            timeout: 180
        )
        try ensureActive(operation)
        return try await reconcileImage(
            currentCard: currentCard,
            serverCard: serverCard,
            placement: placement,
            operation: operation,
            latestCard: latestCard,
            hasPendingWrite: hasPendingWrite,
            onReconciled: onReconciled
        )
    }

    func uploadImage(
        currentCard: StudyCard,
        jpegData: Data,
        placement: StudyCardDraft.ImagePlacement,
        latestCard: @escaping () throws -> StudyCard,
        hasPendingWrite: @escaping (String) throws -> Bool,
        onReconciled: @escaping (StudyCard, Bool, Date) throws -> Void
    ) async throws -> CardImageMutationResult {
        guard placement != .none else { throw InvalidCardImagePlacementError() }
        let operation = try activeOperation()
        let serverCard: StudyCard = try await api.upload(
            "/api/study/cards/\(currentCard.reviewCardID)/image",
            fields: ["imageRole": placement.rawValue],
            fileData: jpegData,
            fileField: "image",
            fileName: "iphone-photo.jpg",
            mimeType: "image/jpeg",
            timeout: 120
        )
        try ensureActive(operation)
        return try await reconcileImage(
            currentCard: currentCard,
            serverCard: serverCard,
            placement: placement,
            operation: operation,
            latestCard: latestCard,
            hasPendingWrite: hasPendingWrite,
            onReconciled: onReconciled
        )
    }

    private func reconcileImage(
        currentCard: StudyCard,
        serverCard: StudyCard,
        placement: StudyCardDraft.ImagePlacement,
        operation: (userID: Int, generation: Int),
        latestCard: () throws -> StudyCard,
        hasPendingWrite: (String) throws -> Bool,
        onReconciled: (StudyCard, Bool, Date) throws -> Void
    ) async throws -> CardImageMutationResult {
        if placement == .both,
           let promptImage = serverCard.prompt["cueImage"],
           let answerImage = serverCard.answer["answerImage"],
           !promptImage.mediaURLs.isEmpty,
           !answerImage.mediaURLs.isEmpty,
           Set(promptImage.mediaURLs.map(MediaCache.stableCacheKey(for:)))
            != Set(answerImage.mediaURLs.map(MediaCache.stableCacheKey(for:)))
        {
            throw MismatchedGeneratedCardImagesError()
        }
        let candidates = placement == .answer
            ? [serverCard.answer["answerImage"], serverCard.prompt["cueImage"]]
            : [serverCard.prompt["cueImage"], serverCard.answer["answerImage"]]
        let generatedImage = candidates.compactMap(\.self).first { !$0.mediaURLs.isEmpty }
        guard let generatedImage, let remoteURL = generatedImage.mediaURLs.first else {
            throw MissingGeneratedCardImageError()
        }
        let localURL = try await mediaCache.refresh(remoteURL, category: "active-study")
        try ensureActive(operation)

        // As with audio, complete reconciliation after server/cache side effects
        // even if the editor has since been dismissed.
        let latest = try latestCard()
        let pendingWrite = try hasPendingWrite(latest.id)
        let latestPromptImage = latest.prompt["cueImage"]
        let latestAnswerImage = latest.answer["answerImage"]
        let promptImage: JSONValue = if placement.includesPrompt {
            generatedImage
        } else if latestPromptImage != currentCard.prompt["cueImage"] {
            latestPromptImage ?? .null
        } else {
            .null
        }
        let answerImage: JSONValue = if placement.includesAnswer {
            generatedImage
        } else if latestAnswerImage != currentCard.answer["answerImage"] {
            latestAnswerImage ?? .null
        } else {
            .null
        }
        let serverUpdatedAt = max(latest.updatedAt, serverCard.updatedAt)
        let updated = StudyCardEditorProjection.reconcilingMedia(
            latest: latest,
            serverCard: serverCard,
            prompt: latest.prompt.replacingObjectValues(["cueImage": promptImage]),
            answer: latest.answer.replacingObjectValues(["answerImage": answerImage]),
            // Image generation does not mutate answer audio. Preserve the
            // freshest local value rather than trusting a lean/stale projection.
            answerAudioSource: latest.answerAudioSource,
            updatedAt: serverUpdatedAt
        )
        try ensureActive(operation)
        try onReconciled(updated, pendingWrite, serverUpdatedAt)
        return CardImageMutationResult(card: updated, localURL: localURL)
    }

    private func activeOperation() throws -> (userID: Int, generation: Int) {
        guard let userID = activeUserID else { throw CancellationError() }
        return (userID, generation)
    }

    private func ensureActive(_ operation: (userID: Int, generation: Int)) throws {
        guard activeUserID == operation.userID, generation == operation.generation else {
            throw CancellationError()
        }
    }
}

private extension String {
    var nilIfTrimmedEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

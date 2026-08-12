import Foundation
import SwiftData

@MainActor
final class PitchAccentResolutionService {
    private struct Operation: Equatable {
        let userID: Int
        let generation: Int
    }

    private struct ResolutionInput: Equatable {
        let cardType: String
        let expression: String?
        let expressionReading: String?
        let promptReading: String?
        let answerAudioTextOverride: String?
        let sentence: String?
        let sentenceReading: String?

        init(card: StudyCard) {
            cardType = card.cardType
            if card.cardType == "cloze" {
                expression = card.answer.firstNonEmptyString(
                    for: ["restoredText", "restoredTextReading", "expression"]
                )
                expressionReading = card.answer.firstNonEmptyString(
                    for: ["restoredTextReading"]
                )
                promptReading = nil
                sentence = card.answer.firstNonEmptyString(
                    for: ["restoredText", "sentenceJp"]
                )
            } else {
                expression = card.answer.firstNonEmptyString(for: ["expression"])
                expressionReading = card.answer.firstNonEmptyString(
                    for: ["expressionReading"]
                )
                promptReading = card.prompt.firstNonEmptyString(for: ["cueReading"])
                sentence = card.answer.firstNonEmptyString(for: ["sentenceJp"])
            }
            answerAudioTextOverride = card.answer.firstNonEmptyString(
                for: ["answerAudioTextOverride"]
            )
            sentenceReading = card.answer.firstNonEmptyString(for: ["sentenceJpKana"])
        }
    }

    private let api: APIClient
    private let context: ModelContext
    private let localCardRepository: StudyCardLocalRepository
    private var activeUserID: Int?
    private var generation = 0

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
        localCardRepository = StudyCardLocalRepository(context: context)
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

    func resolve(
        _ card: StudyCard,
        prepare: @escaping () async throws -> Void,
        onCardPrepared: @escaping (StudyCard) -> Bool,
        hasPendingDelete: @escaping (StudyCard) throws -> Bool
    ) async throws -> StudyCard? {
        let operation = try activeOperation()
        try await prepare()
        try ensureActive(operation)
        guard
            let startingRecord = try localCardRepository.record(
                matching: card,
                userID: operation.userID
            ),
            let currentCard = try? StorageCodec.decoder.decode(
                StudyCard.self,
                from: startingRecord.payload
            ),
            currentCard.answer["pitchAccent"]?["status"]?.stringValue == nil
        else {
            return nil
        }
        let resolutionInput = ResolutionInput(card: currentCard)
        guard onCardPrepared(currentCard) else { throw CancellationError() }

        // The ConvoLab-compatible pitch endpoint returns StudyCard directly,
        // matching the direct card create/update compatibility responses.
        let serverCard: StudyCard = try await api.request(
            "/api/study/cards/\(currentCard.reviewCardID)/pitch-accent",
            method: "POST"
        )
        try ensureActive(operation)
        guard
            try !hasPendingDelete(currentCard),
            let pitchAccent = serverCard.answer["pitchAccent"],
            let latestRecord = try localCardRepository.record(
                matching: currentCard,
                userID: operation.userID
            ),
            let latestCard = try? StorageCodec.decoder.decode(
                StudyCard.self,
                from: latestRecord.payload
            ),
            latestCard.answer["pitchAccent"]?["status"]?.stringValue == nil,
            ResolutionInput(card: latestCard) == resolutionInput
        else {
            return nil
        }

        let updatedCard = StudyCardEditorProjection.reconcilingMedia(
            latest: latestCard,
            serverCard: serverCard,
            prompt: latestCard.prompt,
            answer: latestCard.answer.replacingObjectValues([
                "pitchAccent": pitchAccent,
            ]),
            answerAudioSource: latestCard.answerAudioSource,
            updatedAt: latestCard.updatedAt
        )
        latestRecord.replacePayload(encoded: try StorageCodec.encoder.encode(updatedCard))
        latestRecord.serverUpdatedAt = max(latestRecord.serverUpdatedAt, serverCard.updatedAt)
        try context.save()
        return updatedCard
    }

    private func activeOperation() throws -> Operation {
        guard let activeUserID else { throw CancellationError() }
        return Operation(userID: activeUserID, generation: generation)
    }

    private func ensureActive(_ operation: Operation) throws {
        guard
            activeUserID == operation.userID,
            generation == operation.generation
        else {
            throw CancellationError()
        }
    }
}

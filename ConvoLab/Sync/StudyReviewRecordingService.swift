import Foundation
import SwiftData

struct StagedStudyReview {
    let eventID: String
    let cardBefore: StudyCard
    let cardAfter: StudyCard
}

@MainActor
final class StudyReviewRecordingService {
    private let context: ModelContext
    private let reviewOutbox: ReviewEventOutbox
    private let localCardRepository: StudyCardLocalRepository
    private let reviewProjection: (StudyCard, ReviewRating, Date) throws -> StudyCard
    private var activeUserID: Int?

    init(
        context: ModelContext,
        reviewOutbox: ReviewEventOutbox,
        reviewProjection: @escaping (StudyCard, ReviewRating, Date) throws -> StudyCard
    ) {
        self.context = context
        self.reviewOutbox = reviewOutbox
        self.reviewProjection = reviewProjection
        localCardRepository = StudyCardLocalRepository(context: context)
    }

    func activate(userID: Int) {
        activeUserID = userID
    }

    func deactivate() {
        activeUserID = nil
    }

    func stage(
        card snapshot: StudyCard,
        rating: ReviewRating,
        duration: Duration?,
        reviewedAt: Date,
        deviceID: String,
        queueIndex: Int
    ) throws -> StagedStudyReview {
        guard let userID = activeUserID else { throw CancellationError() }
        let record = try localCardRepository.record(matching: snapshot, userID: userID)
        let cardBefore = try currentCard(snapshot: snapshot, record: record)
        let cardAfter = try reviewProjection(cardBefore, rating, reviewedAt)
        let event = ReviewBatchRequest.Event(
            id: ClientIdentifier.ulid(date: reviewedAt),
            cardID: cardBefore.reviewCardID,
            rating: rating,
            reviewedAt: reviewedAt,
            durationMilliseconds: duration.map(Self.milliseconds),
            clientEventID: UUID().uuidString.lowercased(),
            deviceID: deviceID,
            clientCreatedAt: reviewedAt
        )

        try reviewOutbox.stageEnqueue(event: event, cardBefore: cardBefore)
        let payload = try StorageCodec.encoder.encode(cardAfter)
        if let record {
            record.replacePayload(encoded: payload)
            record.isInActiveSession = false
        } else {
            let newRecord = LocalCardRecord(
                card: cardAfter,
                userID: userID,
                queueIndex: queueIndex,
                payload: payload
            )
            newRecord.isInActiveSession = false
            context.insert(newRecord)
        }
        try context.save()
        return StagedStudyReview(
            eventID: event.id,
            cardBefore: cardBefore,
            cardAfter: cardAfter
        )
    }

    private func currentCard(
        snapshot: StudyCard,
        record: LocalCardRecord?
    ) throws -> StudyCard {
        guard let record else { return snapshot }
        let decoded = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        return record.id == decoded.id
            ? decoded
            : decoded.replacingIdentity(id: record.id, syncId: decoded.reviewCardID)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(
            components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
        )
    }
}

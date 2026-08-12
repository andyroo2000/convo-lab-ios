import Foundation

enum StudyMutationKind: String, Codable, CaseIterable, Sendable {
    case cardCreate
    case cardUpdate
    case cardDelete
    case review

    var title: String {
        switch self {
        case .cardCreate: "Create card"
        case .cardUpdate: "Update card"
        case .cardDelete: "Delete card"
        case .review: "Record review"
        }
    }

    var systemImage: String {
        switch self {
        case .cardCreate: "rectangle.stack.badge.plus"
        case .cardUpdate: "square.and.pencil"
        case .cardDelete: "trash"
        case .review: "checkmark.circle"
        }
    }
}

enum StudyMutationStatus: Equatable, Sendable {
    case pending
    case failed(String)
}

struct FailedStudyChange: Identifiable, Equatable, Sendable {
    let id: String
    let kind: StudyMutationKind
    let resourceID: String
    let detail: String
    let createdAt: Date
    let attemptCount: Int
    let lastAttemptAt: Date?
    let errorMessage: String
}

@MainActor
extension PendingMutation {
    var studyMutationKind: StudyMutationKind? {
        StudyMutationKind(rawValue: kind)
    }

    var studyMutationStatus: StudyMutationStatus {
        lastError.map(StudyMutationStatus.failed) ?? .pending
    }

    func failedStudyChange() -> FailedStudyChange? {
        guard
            let kind = studyMutationKind,
            case let .failed(errorMessage) = studyMutationStatus
        else { return nil }

        return FailedStudyChange(
            id: id,
            kind: kind,
            resourceID: resourceID,
            detail: detail(for: kind),
            createdAt: createdAt,
            attemptCount: attemptCount,
            lastAttemptAt: lastAttemptAt,
            errorMessage: errorMessage
        )
    }

    private func detail(for kind: StudyMutationKind) -> String {
        switch kind {
        case .cardCreate:
            guard let request = try? StorageCodec.decoder.decode(
                CreateStudyCardRequest.self,
                from: payload
            ) else { return "Card \(resourceID)" }
            return request.prompt.preferredText
                ?? request.answer.preferredText
                ?? "Card \(resourceID)"
        case .cardUpdate:
            guard let request = try? StorageCodec.decoder.decode(
                UpdateStudyCardRequest.self,
                from: payload
            ) else { return "Card \(resourceID)" }
            return request.prompt.preferredText
                ?? request.answer.preferredText
                ?? "Card \(resourceID)"
        case .cardDelete:
            return "Card \(resourceID)"
        case .review:
            guard let wrapped = try? StorageCodec.decoder.decode(
                PendingReviewPayload.self,
                from: payload
            ) else { return "Card \(resourceID)" }
            return "\(wrapped.event.rating.title) rating for card \(resourceID)"
        }
    }
}

private extension ReviewRating {
    var title: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
}

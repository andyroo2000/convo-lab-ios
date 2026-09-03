import Foundation

struct StudyCardMediaMutationCallbacks {
    let latestCard: () throws -> StudyCard
    let hasPendingWrite: (String) throws -> Bool
    let onReconciled: (StudyCard, Bool, Date) throws -> Void
}

enum StudyCardMediaMutationInput {
    static func validatedImagePrompt(
        _ prompt: String,
        placement: StudyCardDraft.ImagePlacement,
        maximumCharacters: Int
    ) throws -> String {
        let imagePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !imagePrompt.isEmpty, imagePrompt.count <= maximumCharacters else {
            throw InvalidCardImagePromptError(maximumCharacters: maximumCharacters)
        }
        guard placement != .none else {
            throw InvalidCardImagePlacementError()
        }
        return imagePrompt
    }

    static func validateImageUpload(
        _ jpegData: Data,
        placement: StudyCardDraft.ImagePlacement,
        maximumBytes: Int
    ) throws {
        guard placement != .none else {
            throw InvalidCardImagePlacementError()
        }
        guard jpegData.count <= maximumBytes else {
            throw OversizedCardImageUploadError(maximumBytes: maximumBytes)
        }
    }
}

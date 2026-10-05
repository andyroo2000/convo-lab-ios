import XCTest
@testable import ConvoLab

final class StudyCardImageGenerationTests: XCTestCase {
    @MainActor
    func testImageLessSentenceGetsAnAutomaticPromptForEveryPlacement() {
        var draft = StudyCardDraft()
        draft.answerExpression = "河童は日本の伝説に出てきます。"
        draft.answerMeaning = "Kappa appear in Japanese legends."
        draft.imagePrompt = " \n "

        for placement in StudyCardDraft.ImagePlacement.allCases {
            draft.imagePlacement = placement
            XCTAssertFalse(draft.hasImage)
            XCTAssertEqual(
                draft.resolvedImagePrompt(maximumCharacters: 1000),
                "A clear natural real-world image representing 河童は日本の伝説に出てきます。 (Kappa appear in Japanese legends.)."
            )
        }
    }

    @MainActor
    func testCustomImagePromptTakesPrecedenceOverSentence() {
        var draft = StudyCardDraft()
        draft.answerExpression = "河童は日本の伝説に出てきます。"
        draft.imagePrompt = " A friendly kappa next to a Japanese river. \n"
        XCTAssertEqual(draft.resolvedImagePrompt(maximumCharacters: 1000), "A friendly kappa next to a Japanese river.")
    }

    @MainActor
    func testImagePresenceTracksGenerationAndRemovalWithoutDependingOnPlacement() {
        var draft = StudyCardDraft()
        draft.currentImage = .null
        XCTAssertFalse(draft.hasImage)
        draft.currentImage = .object(["url": .string("https://example.com/kappa.png")])
        for placement in StudyCardDraft.ImagePlacement.allCases {
            draft.imagePlacement = placement
            XCTAssertTrue(draft.hasImage)
        }
        draft.currentImage = nil
        XCTAssertFalse(draft.hasImage)
    }

    @MainActor
    func testAutomaticPromptFitsTheServerLimitWithoutTruncatingCustomPrompts() {
        var draft = StudyCardDraft()
        draft.answerExpression = String(repeating: "河童", count: 100)
        XCTAssertEqual(draft.resolvedImagePrompt(maximumCharacters: 80).count, 80)
        draft.imagePrompt = String(repeating: "kappa", count: 100)
        XCTAssertEqual(draft.resolvedImagePrompt(maximumCharacters: 80), draft.imagePrompt)
    }

}

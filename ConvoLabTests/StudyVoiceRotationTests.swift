import XCTest
@testable import ConvoLab

@MainActor
final class StudyVoiceRotationTests: XCTestCase {
    func testEveryAdvertisedVoiceCanBeUsedForNewDrafts() throws {
        var capabilities = StudyCapabilities.fallback.cardAuthoring
        XCTAssertEqual(capabilities.defaultAnswerAudioVoiceIds?.count, 19)
        for voice in StudyAnswerVoice.japanese {
            capabilities.defaultAnswerAudioVoiceIds = [voice.id]
            let decoded = try JSONDecoder().decode(
                StudyCapabilities.CardAuthoring.self,
                from: JSONEncoder().encode(capabilities)
            )
            let draft = StudyCardDraft(defaultAnswerAudioVoiceID: decoded.randomDefaultVoiceId())
            XCTAssertEqual(draft.answerAudioVoiceId, voice.id)
        }
    }

    func testMissingOrEmptyPoolFallsBackToLegacyDefault() throws {
        var capabilities = StudyCapabilities.fallback.cardAuthoring
        capabilities.defaultAnswerAudioVoiceIds = nil
        let decoded = try JSONDecoder().decode(
            StudyCapabilities.CardAuthoring.self,
            from: JSONEncoder().encode(capabilities)
        )
        XCTAssertEqual(decoded.randomDefaultVoiceId(), decoded.defaultAnswerAudioVoiceId)
        capabilities.defaultAnswerAudioVoiceIds = ["", "  "]
        XCTAssertEqual(capabilities.randomDefaultVoiceId(), capabilities.defaultAnswerAudioVoiceId)
    }
    func testEditorSamplesOnlyForBrandNewDrafts() {
        var capabilities = StudyCapabilities.fallback.cardAuthoring
        capabilities.defaultAnswerAudioVoiceIds = ["new-draft-voice"]
        let newDraft = CardEditorView.resolveInitialDraft(
            card: nil, serverDraft: nil, initialDraft: nil, capabilities: capabilities
        )
        XCTAssertEqual(newDraft.answerAudioVoiceId, "new-draft-voice")
        var savedDraft = newDraft
        savedDraft.answerAudioVoiceId = "chosen-voice"
        let recovered = CardEditorView.resolveInitialDraft(
            card: nil, serverDraft: nil, initialDraft: savedDraft, capabilities: capabilities
        )
        XCTAssertEqual(recovered.answerAudioVoiceId, "chosen-voice")
        XCTAssertEqual(capabilities.defaultAnswerAudioVoiceId, StudyAnswerVoice.defaultVoice.id)
        XCTAssertTrue(StudyAnswerVoice.japanese.map(\.id).contains(
            StudyCapabilities.fallback.cardAuthoring.randomDefaultVoiceId()
        ))
    }

}

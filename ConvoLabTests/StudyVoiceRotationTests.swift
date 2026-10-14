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
            let draft = StudyCardDraft(defaultAnswerAudioVoiceID: decoded.defaultAnswerAudioVoiceId)
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
        XCTAssertEqual(decoded.defaultAnswerAudioVoiceId, decoded.legacyDefaultAnswerAudioVoiceId)
        capabilities.defaultAnswerAudioVoiceIds = ["", "  "]
        XCTAssertEqual(capabilities.defaultAnswerAudioVoiceId, capabilities.legacyDefaultAnswerAudioVoiceId)
    }
}

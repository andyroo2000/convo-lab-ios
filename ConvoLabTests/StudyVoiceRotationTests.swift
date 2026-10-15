import XCTest
@testable import ConvoLab

@MainActor
final class StudyVoiceRotationTests: XCTestCase {
    func testEveryAdvertisedVoiceCanBeUsedForNewDrafts() throws {
        var capabilities = StudyCapabilities.fallback.cardAuthoring
        XCTAssertEqual(capabilities.defaultAnswerAudioVoiceIds?.count, 14)
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

    func testLegacyVoicesStayNamedAndPreserveSavedDrafts() {
        let retiredNames: Set<String> = ["Ren", "Otani", "Nakamura", "Satoru", "ゆあ"]
        let retired = StudyAnswerVoice.allJapanese.filter(\.isLegacy)
        XCTAssertEqual(Set(retired.map(\.name)), retiredNames)
        XCTAssertFalse(StudyAnswerVoice.defaultVoice.isLegacy)
        for voice in retired {
            XCTAssertFalse(StudyAnswerVoice.japanese.contains(voice))
            XCTAssertTrue(StudyAnswerVoice.currentVoiceLabel(for: voice.id).contains("Legacy"))
            let saved = StudyCardDraft(defaultAnswerAudioVoiceID: voice.id)
            let restored = CardEditorView.resolveInitialDraft(
                card: nil, serverDraft: nil, initialDraft: saved,
                capabilities: StudyCapabilities.fallback.cardAuthoring
            )
            XCTAssertEqual(restored.answerAudioVoiceId, voice.id)
        }
    }

    func testPickerLabelsIdentifyMaleAndFemaleVoices() {
        XCTAssertEqual(StudyAnswerVoice.defaultVoice.pickerLabel, "Sato · M — Warm izakaya owner")
        let kyoko = StudyAnswerVoice.japanese.first { $0.name == "Kyoko" }
        XCTAssertEqual(kyoko?.pickerLabel, "Kyoko · F — Polite and composed")
        XCTAssertEqual(StudyAnswerVoice.currentVoiceLabel(for: "unknown"), "Current voice")
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

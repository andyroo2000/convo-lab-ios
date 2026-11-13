import XCTest
@testable import ConvoLab

final class JournalVersionCopyTests: XCTestCase {
    @MainActor
    func testDraftCopiesSourceTextWithoutFuriganaOrCorrections() {
        XCTAssertEqual(JournalVersionCopy.text(version: .draft, analysis: analysis()), "映画を見ますた。")
    }
    @MainActor
    func testFinalPrefersTheSavedDocumentAndFallsBackToAnalysis() {
        var value = analysis()
        XCTAssertEqual(JournalVersionCopy.text(version: .final, analysis: value), "映画を見ました。")
        value.correctedDocument = JournalCorrectedDocument(text: "映画を見た。", reading: "映画[えいが]を見[み]た。", suggestions: [])
        XCTAssertEqual(JournalVersionCopy.text(version: .final, analysis: value), "映画を見た。")
    }
    @MainActor
    func testLegacyAnswerIsIncludedOnlyWhenItAppearsInTheDraft() {
        var value = analysis()
        value.currentReply = JournalReply(id: "reply", parentId: nil, answer: "映画を見ますた。", status: .ready, result: value.result, error: nil)
        XCTAssertEqual(JournalVersionCopy.text(version: .draft, analysis: value), "映画を見ますた。\n\n映画を見ますた。")
    }
    @MainActor
    func testMissingFeedbackCopiesEmptyText() {
        let value = JournalAnalysis(id: "analysis", sourceVersion: 1, status: .queued, result: nil, error: nil, updatedAt: "now")
        XCTAssertEqual(JournalVersionCopy.text(version: .final, analysis: value), "")
        XCTAssertEqual(JournalVersionCopy.text(version: .draft, analysis: value), "")
    }
    private func analysis() -> JournalAnalysis {
        let segment = JournalSegment(text: "映画を見ますた。", reading: "映画[えいが]を見[み]ますた。", kind: .correction, suggestion: nil, suggestionReading: nil, explanation: nil, explanationReading: nil)
        let result = JournalFeedback(title: "Movie", correctedText: "映画を見ました。", correctedReading: "映画[えいが]を見[み]ました。", question: "", questionReading: "", questionTranslation: "", segments: [segment])
        return JournalAnalysis(id: "analysis", sourceVersion: 1, status: .ready, result: result, error: nil, updatedAt: "now")
    }
}

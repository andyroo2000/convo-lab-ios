import SwiftUI
import XCTest
@testable import ConvoLab

@MainActor
final class JournalTypingCoordinatorTests: XCTestCase {
    func testSuggestionsNeverReplaceKanaUntilTapped() throws {
        let model = try XCTUnwrap(JournalNativeComposition())
        let state = model.call("edit", [["text": "", "range": [0, 0], "replacement": "kyouhatanoshikatta", "selection": [0, 0]]])
        XCTAssertEqual(state.text, "きょうはたのしかった")
        let candidates: [String: Any] = ["candidates": [["text": "今日は楽しかった"]]]
        let suggested = model.call("receive", [state.reading, candidates])
        XCTAssertEqual(suggested.text, state.text)
        XCTAssertEqual(suggested.caret, state.caret)
        XCTAssertEqual(suggested.choices.first, "今日は楽しかった")
        XCTAssertTrue(suggested.choices.contains("kyouhatanoshikatta"))
        let committed = model.call("choose", [0])
        XCTAssertEqual(committed.text, "今日は楽しかった")
        XCTAssertNil(committed.composition)
    }

    func testOnlyConfirmedSelectionsCrossTheLearningBridgeOnce() throws {
        let model = try XCTUnwrap(JournalNativeComposition())
        _ = model.call("edit", [["text": "", "range": [0, 0], "replacement": "ame", "selection": [0, 0]]])
        _ = model.call("receive", ["あめ", ["candidates": [["text": "飴"]]]])
        XCTAssertTrue(model.takeConfirmedConversions().isEmpty)
        _ = model.call("choose", [0])
        let selections = model.takeConfirmedConversions()
        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections.first?["text"] as? String, "飴")
        XCTAssertEqual(selections.first?["reading"] as? String, "あめ")
        XCTAssertEqual(selections.first?["end"] as? Int, 2)
        XCTAssertTrue(model.takeConfirmedConversions().isEmpty)
        _ = model.call("commit")
        XCTAssertTrue(model.takeConfirmedConversions().isEmpty)
    }

    func testOldSuggestionsCannotChangeAnEditedDocument() throws {
        let model = try XCTUnwrap(JournalNativeComposition())
        let state = model.call("edit", [["text": "", "range": [0, 0], "replacement": "ame", "selection": [0, 0]]])
        _ = model.call("external", ["Different entry"])
        let stale = model.call("receive", [state.reading, ["candidates": [["text": "雨"]]]])
        XCTAssertEqual(stale.text, "Different entry")
        XCTAssertTrue(stale.choices.isEmpty)
    }

    func testNativeDeleteAfterCommitUpdatesBinding() throws {
        var text = ""
        let coordinator = JournalTypingCoordinator(text: Binding(get: { text }, set: { text = $0 }))
        let view = JournalNativeTextView()
        coordinator.attach(view)
        coordinator.configure(text: text, font: .systemFont(ofSize: 20))
        for character in "ohayou" {
            XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: String(character)))
        }
        XCTAssertEqual(text, "おはよう")
        coordinator.commit()
        XCTAssertNil(coordinator.composition?.state.composition)
        view.deleteBackward()
        XCTAssertEqual(view.text, "おはよ")
        XCTAssertEqual(text, "おはよ")
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: "u"))
        XCTAssertEqual(text, "おはよう")
        coordinator.stop()
    }

    func testPunctuationAndNumbersKeepNativeCompositionActive() throws {
        var text = ""
        let coordinator = JournalTypingCoordinator(text: Binding(get: { text }, set: { text = $0 }))
        let view = JournalNativeTextView()
        coordinator.attach(view)
        coordinator.configure(text: text, font: .systemFont(ofSize: 20))
        for character in "ame1." {
            XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: String(character)))
        }
        XCTAssertEqual(text, "あめ1。")
        XCTAssertEqual(coordinator.composition?.state.reading, text)
        XCTAssertEqual(coordinator.composition?.state.composition, [0, 4])
        view.deleteBackward()
        XCTAssertEqual(text, "あめ1")
        XCTAssertNotNil(coordinator.composition?.state.composition)
        coordinator.stop()
    }

    func testCandidatePanelExpandsWithoutDroppingChoices() {
        let bar = JournalCandidateBar()
        bar.traitOverrides.verticalSizeClass = .regular
        bar.updateTraitsIfNeeded()
        bar.frame.size.width = 390
        let choices = (0..<160).map { "候補\($0)" }
        bar.update(choices, context: "こうほ")
        bar.toggleExpanded()
        XCTAssertTrue(bar.expanded)
        XCTAssertEqual(bar.intrinsicContentSize.height, 216)
        let collection = bar.subviews.compactMap { $0 as? UICollectionView }.first!
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 160)
        bar.toggleExpanded()
        XCTAssertEqual(bar.intrinsicContentSize.height, 48)
        bar.update([], context: "")
        var dismissed = false
        bar.dismissKeyboard = { dismissed = true }
        bar.toggleExpanded()
        XCTAssertTrue(dismissed)
    }

    func testExpandedCandidatesFitCompactHeightAndCollapseWhenEmpty() {
        let bar = JournalCandidateBar()
        bar.traitOverrides.verticalSizeClass = .compact
        bar.updateTraitsIfNeeded()
        bar.frame.size.width = 780
        bar.update(["雨", "飴"], context: "あめ")
        bar.toggleExpanded()
        XCTAssertEqual(bar.intrinsicContentSize.height, 96)
        let button = bar.subviews.compactMap { $0 as? UIButton }.first!
        XCTAssertEqual(button.accessibilityValue, "Expanded")
        bar.update([], context: "")
        XCTAssertFalse(bar.expanded)
        XCTAssertEqual(bar.intrinsicContentSize.height, 48)
        XCTAssertEqual(button.accessibilityLabel, "Hide keyboard")
    }

    func testExactLatinSpellingCanBeCommitted() throws {
        let model = try XCTUnwrap(JournalNativeComposition())
        let state = model.call("edit", [["text": "", "range": [0, 0], "replacement": "OpenAI", "selection": [0, 0]]])
        let index = try XCTUnwrap(state.choices.firstIndex(of: "OpenAI"))
        XCTAssertEqual(model.call("choose", [index]).text, "OpenAI")
    }
    func testSectionAdjustmentWorksInIOSJavaScriptCore() throws {
        let model = try XCTUnwrap(JournalNativeComposition())
        _ = model.call("edit", [["text": "", "range": [0, 0], "replacement": "hashidetabemashita", "selection": [0, 0]]])
        let candidate: [String: Any] = ["text": "箸で食べました", "sections": [
            ["reading": "はしで", "text": "箸で"], ["reading": "たべました", "text": "食べました"],
        ]]
        _ = model.call("receive", ["はしでたべました", ["candidates": [candidate]]])
        _ = model.call("focusSection", [1])
        let resized = model.call("resize", [-1])
        XCTAssertEqual(resized.boundaries, [2])
        XCTAssertEqual(resized.reading, "はしでたべました")
        XCTAssertEqual(resized.text, "はしでたべました")
        XCTAssertNotNil(resized.section)
    }

    func testPastePreservesLatinPunctuationAndNewlines() {
        var text = ""
        let coordinator = JournalTypingCoordinator(text: Binding(get: { text }, set: { text = $0 }))
        let view = JournalNativeTextView()
        coordinator.attach(view)
        coordinator.configure(text: text, font: .systemFont(ofSize: 20))
        for value in ["a", "/", "OpenAI\nhttps://example.com"] { coordinator.paste(value) }
        XCTAssertEqual(text, "a/OpenAI\nhttps://example.com")
        XCTAssertNil(coordinator.composition?.state.composition)
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: "another"))
        coordinator.stop()
    }

    func testComposerFailureOffersFallbackOnce() {
        let coordinator = JournalTypingCoordinator(text: .constant("Preserved"), composition: nil)
        let view = JournalNativeTextView()
        var notices = 0
        coordinator.unavailable = { notices += 1 }
        coordinator.attach(view)
        coordinator.configure(text: "Preserved", font: .systemFont(ofSize: 20))
        coordinator.textViewDidBeginEditing(view)
        coordinator.textViewDidBeginEditing(view)
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(view.text, "Preserved")
        coordinator.stop()
    }

    func testExternalReplacementDuringCompositionClearsOldCandidates() {
        var text = ""
        let coordinator = JournalTypingCoordinator(text: Binding(get: { text }, set: { text = $0 }))
        let view = JournalNativeTextView()
        coordinator.attach(view)
        coordinator.configure(text: text, font: .systemFont(ofSize: 20))
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: "a"))
        XCTAssertNotNil(coordinator.composition?.state.composition)
        text = "Different entry"
        coordinator.configure(text: text, font: .systemFont(ofSize: 20))
        XCTAssertNil(coordinator.composition?.state.composition)
        XCTAssertEqual(view.text, text)
        coordinator.stop()
    }

    func testOnlyThisEditorsDockedKeyboardShowsTheFooter() {
        let window = CGRect(x: 0, y: 0, width: 400, height: 800)
        let keyboard = CGRect(x: 0, y: 500, width: 400, height: 300)
        var dock = JournalKeyboardDock(focusedWindow: nil, keyboardFrame: keyboard)
        XCTAssertFalse(dock.visible)
        dock.focusedWindow = window
        XCTAssertTrue(dock.visible)
        dock.keyboardFrame = CGRect(x: 100, y: 300, width: 200, height: 200)
        XCTAssertFalse(dock.visible, "Floating keyboard must not add a bottom footer")
        dock.keyboardFrame = CGRect(x: 0, y: 800, width: 400, height: 0)
        XCTAssertFalse(dock.visible, "Hardware keyboard must not add a bottom footer")
    }

}

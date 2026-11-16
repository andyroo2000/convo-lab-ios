import SwiftUI
import XCTest
import UIKit
@testable import ConvoLab

@MainActor
final class JournalWritingFieldTests: XCTestCase {
    func testWritingGrowsWrapsAndShrinksWithoutAnInnerScrollView() {
        let view = JournalWritingTextView()
        let font = JournalTypography().unscaledFont
        view.configure(text: "", font: font)
        let empty = view.fittingSize(width: 280, minimumLines: 4)
        XCTAssertEqual(empty.height, font.pointSize * JournalPaperText.linePitch * 4)
        XCTAssertFalse(view.isScrollEnabled)
        let text = String(repeating: "今日は友達と映画を見ました。\n", count: 12)
        view.configure(text: text, font: font)
        let long = view.fittingSize(width: 280, minimumLines: 4)
        XCTAssertGreaterThan(long.height, empty.height)
        XCTAssertGreaterThan(view.fittingSize(width: 140, minimumLines: 4).height, long.height)
        view.configure(text: "短い文。", font: font)
        XCTAssertEqual(view.fittingSize(width: 280, minimumLines: 4), empty)
    }

    func testTrailingBlankLinesAndRepeatedUpdatesPreserveWriting() {
        let view = JournalWritingTextView()
        let font = JournalTypography().unscaledFont
        let text = "一行目。\n二行目。\n\n\n\n\n"
        view.configure(text: text, font: font)
        let trailing = view.fittingSize(width: 280, minimumLines: 1)
        view.selectedRange = NSRange(location: 2, length: 2)
        view.configure(text: text, font: font)
        XCTAssertEqual(view.text, text)
        XCTAssertEqual(view.selectedRange, NSRange(location: 2, length: 2))
        view.configure(text: text.trimmingCharacters(in: .newlines), font: font)
        XCTAssertGreaterThan(trailing.height, view.fittingSize(width: 280, minimumLines: 1).height)
        XCTAssertEqual(view.textContainerInset, .zero)
        XCTAssertEqual(view.textContainer.lineFragmentPadding, 0)
    }

    func testNativeTypingKeepsEveryParagraphOnTheNotebookPitch() {
        let view = JournalWritingTextView()
        let font = JournalTypography().unscaledFont
        view.configure(text: "", font: font)
        for character in "First line.\nSecond line.\nThird line.\n\n" {
            view.insertText(String(character))
            view.configure(text: view.text, font: font)
        }
        view.attributedText.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: view.attributedText.length)) { value, _, _ in
            let paragraph = value as? NSParagraphStyle
            XCTAssertEqual(paragraph?.minimumLineHeight, font.pointSize * JournalPaperText.linePitch)
            XCTAssertEqual(paragraph?.maximumLineHeight, font.pointSize * JournalPaperText.linePitch)
        }
    }

    func testRenderedParagraphBaselinesUseThePaperPitch() {
        for selection in ["klee", "sans", "serif"] {
            let view = JournalWritingTextView()
            view.frame = CGRect(x: 0, y: 0, width: 280, height: 700)
            let font = JournalTypography(font: selection).unscaledFont
            view.configure(text: "First line.\nSecond line.\nThird line.", font: font)
            view.layoutIfNeeded()
            let first = view.caretRect(for: view.beginningOfDocument)
            let second = view.caretRect(for: view.position(from: view.beginningOfDocument, offset: 12)!)
            XCTAssertEqual(second.minY - first.minY, font.pointSize * JournalPaperText.linePitch, accuracy: 1, selection)
        }
    }

    func testBindingRoundTripKeepsSelectionAndGrowingCaretVisible() {
        var text = ""
        let coordinator = JournalWritingField.Coordinator(text: Binding(get: { text }, set: { text = $0 }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let scroll = UIScrollView(frame: window.bounds)
        controller.view.addSubview(scroll)
        let view = JournalWritingTextView()
        view.delegate = coordinator
        scroll.addSubview(view)
        let font = JournalTypography().unscaledFont
        view.configure(text: "", font: font)
        view.becomeFirstResponder()
        view.insertText(String(repeating: "Another line.\n", count: 20))
        coordinator.textViewDidChange(view)
        let selection = view.selectedRange
        view.configure(text: text, font: font)
        view.frame = CGRect(origin: .zero, size: view.fittingSize(width: 280, minimumLines: 4))
        scroll.contentSize = CGSize(width: view.frame.width, height: view.frame.height + 40)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(text, view.text)
        XCTAssertEqual(view.selectedRange, selection)
        let caret = view.convert(view.caretRect(for: view.selectedTextRange!.end), to: scroll)
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        XCTAssertLessThanOrEqual(caret.maxY, scroll.bounds.maxY)
        scroll.contentOffset = .zero
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(scroll.contentOffset.y, 0, "Unrelated layout must not undo manual scrolling")
    }

    func testMarkedJapaneseTextIsNotReplacedByAnUpdate() {
        let view = JournalWritingTextView()
        let font = JournalTypography().unscaledFont
        view.configure(text: "", font: font)
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        view.configure(text: "stale value", font: font)
        XCTAssertEqual(view.text, "にほん")
        view.unmarkText()
    }
}

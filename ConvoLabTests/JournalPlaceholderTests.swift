import XCTest
@testable import ConvoLab

@MainActor
final class JournalPlaceholderTests: XCTestCase {
    func testPlaceholderTracksCaretAndSelectedTypographyAcrossFontChanges() throws {
        let editor = JournalWritingTextView()
        editor.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        for selection in ["klee", "sans", "serif"] {
            for size: CGFloat in [16, 23, 30, 42] {
                let font = JournalTypography(font: selection).unscaledFont.withSize(size)
                editor.configure(text: "", font: font)
                editor.layoutIfNeeded()
                let placeholder = try XCTUnwrap(editor.subviews.compactMap { $0 as? UITextView }.first)
                placeholder.layoutIfNeeded()
                XCTAssertEqual(placeholder.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont, font)
                XCTAssertEqual(placeholder.text, "今日は…")
                XCTAssertFalse(placeholder.isHidden)
                XCTAssertFalse(placeholder.isUserInteractionEnabled)
                XCTAssertTrue(placeholder.accessibilityElementsHidden)
                let caret = editor.caretRect(for: editor.beginningOfDocument)
                let previewCaret = placeholder.convert(placeholder.caretRect(for: placeholder.beginningOfDocument), to: editor)
                XCTAssertEqual(previewCaret.minY, caret.minY, accuracy: 1, "\(selection) \(size)")
                editor.configure(text: "今日は…", font: font)
                editor.layoutIfNeeded()
                XCTAssertTrue(placeholder.isHidden)
                let typed = editor.caretRect(for: editor.beginningOfDocument)
                XCTAssertEqual(previewCaret.minY, typed.minY, accuracy: 1, "\(selection) \(size)")
                XCTAssertEqual(editor.text, "今日は…")
            }
        }
    }
}

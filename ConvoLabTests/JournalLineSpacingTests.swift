import XCTest
import UIKit
@testable import ConvoLab

@MainActor
final class JournalLineSpacingTests: XCTestCase {
    func testEnglishJapaneseAndRubyUseOneBaselinePitch() throws {
        for size in [16.0, 23.0, 38.0] {
            for width in [160.0, 332.0] { try checkPitch(size: size, width: width) }
        }
    }

    private func checkPitch(size: CGFloat, width: CGFloat) throws {
        let segment = JournalSegment(text: "", reading: "", kind: .correction, suggestion: nil,
            suggestionReading: nil, explanation: "Use レッスン for the spelling. 中止[ちゅうし]になった means **was canceled** and fits a scheduled lesson. With が取り消した, the lesson itself would be doing the canceling. Use 中止 for the event and explain who canceled it in the next sentence.", explanationReading: nil)
        let text = JournalExplanationContent.attributed(segment, knownKanji: [], font: UIFont(name: "Georgia", size: size)!)
        let view = UITextView(usingTextLayoutManager: true)
        view.textLayoutManager?.usesFontLeading = false
        view.isScrollEnabled = false
        view.textContainer.lineFragmentPadding = 0
        view.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
        let manager = try XCTUnwrap(view.textLayoutManager)
        let layout = JournalExplanationLayout()
        layout.update(text, font: UIFont(name: "Georgia", size: size)!)
        manager.delegate = layout
        view.attributedText = text
        view.layoutIfNeeded()
        var baselines: [CGFloat] = []
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                baselines.append(fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
            }
            return true
        }
        XCTAssertGreaterThan(baselines.count, 3)
        let pitch = try XCTUnwrap((text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight)
        for (a, b) in zip(baselines, baselines.dropFirst()) {
            XCTAssertEqual(b - a, pitch, accuracy: 0.5, "size \(size), width \(width), baselines \(baselines)")
        }
    }
}

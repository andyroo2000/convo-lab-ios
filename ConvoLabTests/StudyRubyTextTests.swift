import CoreText
import UIKit
import XCTest
@testable import ConvoLab

@MainActor
final class StudyRubyTextTests: XCTestCase {
    func testFuriganaIsVisibleByDefault() {
        let document = StudyRubyDocument.parse(
            "会社[かいしゃ]で働[はたら]く",
            knownKanji: []
        )

        XCTAssertEqual(
            document.segments,
            [
                .ruby(base: "会社", reading: "かいしゃ"),
                .text("で"),
                .ruby(base: "働", reading: "はたら"),
                .text("く"),
            ]
        )
        XCTAssertEqual(document.plainText, "会社で働く")
        XCTAssertTrue(document.hasRuby)
    }

    func testReadingHidesOnlyWhenEveryKanjiInAnnotatedWordIsKnown() {
        let partiallyKnown = StudyRubyDocument.parse(
            "会社[かいしゃ]",
            knownKanji: ["会"]
        )
        let fullyKnown = StudyRubyDocument.parse(
            "会社[かいしゃ]",
            knownKanji: ["会", "社"]
        )

        XCTAssertEqual(
            partiallyKnown.segments,
            [.ruby(base: "会社", reading: "かいしゃ")]
        )
        XCTAssertEqual(fullyKnown.segments, [.text("会社")])
        XCTAssertFalse(fullyKnown.hasRuby)
    }

    func testParticlesAndOkuriganaStayOutsideRuby() {
        let document = StudyRubyDocument.parse(
            "彼[かれ]は深[ふか]く息[いき]を吸[す]っています",
            knownKanji: []
        )

        XCTAssertEqual(
            document.segments,
            [
                .ruby(base: "彼", reading: "かれ"),
                .text("は"),
                .ruby(base: "深", reading: "ふか"),
                .text("く"),
                .ruby(base: "息", reading: "いき"),
                .text("を"),
                .ruby(base: "吸", reading: "す"),
                .text("っています"),
            ]
        )
    }

    func testParticleMatchingStartOfFollowingReadingIsNotRemoved() {
        let document = StudyRubyDocument.parse(
            "虫[むし]は本当[ほんとう]に苦手[にがて]。",
            knownKanji: []
        )

        XCTAssertEqual(
            document.segments,
            [
                .ruby(base: "虫", reading: "むし"),
                .text("は"),
                .ruby(base: "本当", reading: "ほんとう"),
                .text("に"),
                .ruby(base: "苦手", reading: "にがて"),
                .text("。"),
            ]
        )
    }

    func testAnkiParentheticalReadingIsParsedButOrdinaryParentheticalTextIsPreserved() {
        let document = StudyRubyDocument.parse(
            "予定(よてい)（変更あり）計画(plan)",
            knownKanji: []
        )

        XCTAssertEqual(
            document.segments,
            [
                .ruby(base: "予定", reading: "よてい"),
                .text("（変更あり）計画(plan)"),
            ]
        )
    }

    func testKanaOnlyBracketTextIsPreservedInsteadOfRenderedAsRuby() {
        let document = StudyRubyDocument.parse(
            "かな[かな]",
            knownKanji: []
        )

        XCTAssertEqual(document.segments, [.text("かな[かな]")])
        XCTAssertFalse(document.hasRuby)
    }

    func testClozeBlankAfterKanjiIsNotParsedAsRuby() {
        let document = StudyRubyDocument.parse(
            "日本[...]を勉強する",
            knownKanji: []
        )

        XCTAssertEqual(document.segments, [.text("日本[...]を勉強する")])
        XCTAssertEqual(document.plainText, "日本[...]を勉強する")
        XCTAssertFalse(document.hasRuby)
    }

    func testIterationMarkDoesNotPreventKnownWordFromHidingItsReading() {
        let document = StudyRubyDocument.parse(
            "時々[ときどき]",
            knownKanji: ["時"]
        )

        XCTAssertEqual(document.segments, [.text("時々")])
    }

    func testMultiCharacterRubyBaseRemainsOneContinuousAnnotation() {
        let document = StudyRubyDocument.parse(
            "多[おお]くの経験[けいけん]豊[ゆた]かな人",
            knownKanji: ["多"]
        )

        let rendered = document.attributedString(
            pointSize: 38,
            weight: .semibold,
            color: .label,
            alignment: .center
        )

        XCTAssertEqual(rendered.string, document.plainText)

        let experienceRange = (rendered.string as NSString).range(of: "経験")
        var effectiveRange = NSRange()
        XCTAssertNotNil(rendered.attribute(
            NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
            at: experienceRange.location,
            effectiveRange: &effectiveRange
        ))
        XCTAssertEqual(effectiveRange, experienceRange)
    }

    func testLineBreakDelegateRejectsBreakInsideRubyRange() {
        let document = StudyRubyDocument.parse(
            "経験[けいけん]豊富[ほうふ]",
            knownKanji: []
        )
        let attributedText = document.attributedString(
            pointSize: 38,
            weight: .semibold,
            color: .label,
            alignment: .center
        )
        let delegate = StudyRubyLineBreakDelegate()
        delegate.updateRubyRanges(in: attributedText)

        XCTAssertFalse(delegate.shouldBreakLine(beforeCharacterAt: 1))
        XCTAssertTrue(delegate.shouldBreakLine(beforeCharacterAt: 2))
        XCTAssertFalse(delegate.shouldBreakLine(beforeCharacterAt: 3))
    }

    func testRubyTextViewStaysOnTextKit2() {
        let view = UITextView(usingTextLayoutManager: true)
        let delegate = StudyRubyLineBreakDelegate()
        view.textLayoutManager?.delegate = delegate

        XCTAssertNotNil(view.textLayoutManager)
        XCTAssertTrue(view.textLayoutManager?.delegate === delegate)
    }

    func testTextKit2ViewActuallyDrawsRubyAnnotation() {
        let document = StudyRubyDocument.parse(
            """
            営業[えいぎょう]する
            研究[けんきゅう]
            講義[こうぎ]
            友[とも]だちは東京[とうきょう]に引[ひ]っ越[こ]しました。
            """,
            knownKanji: []
        )
        let rubyText = document.attributedString(
            pointSize: 38,
            weight: .semibold,
            color: .black,
            alignment: .center
        )
        let plainText = NSMutableAttributedString(attributedString: rubyText)
        plainText.removeAttribute(
            NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
            range: NSRange(location: 0, length: plainText.length)
        )
        let rubyImage = renderedImage(for: rubyText)
        let attachment = XCTAttachment(image: rubyImage)
        attachment.name = "TextKit 2 furigana visual reference"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertNotEqual(
            rubyImage.pngData(),
            renderedImage(for: plainText).pngData(),
            "The TextKit 2 view must draw the ruby glyphs, not merely retain their attribute."
        )
    }

    private func renderedImage(for text: NSAttributedString) -> UIImage {
        let view = UITextView(usingTextLayoutManager: true)
        let delegate = StudyRubyLineBreakDelegate()
        delegate.updateRubyRanges(in: text)
        view.textLayoutManager?.delegate = delegate
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 430)
        view.backgroundColor = .white
        view.textContainerInset = UIEdgeInsets(top: 48, left: 0, bottom: 0, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.attributedText = text
        view.layoutIfNeeded()

        return UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    func testJapaneseWrapsInsideCompoundWithoutRuby() {
        XCTAssertEqual(renderedLines("あいう映画です", columns: 4).first, "あいう映")
    }

    func testKnownKanjiWrapsInsideCompoundAfterHidingRuby() {
        XCTAssertEqual(
            renderedLines("あいう映画[あいうえいが]です", columns: 4, knownKanji: ["映", "画"]).first,
            "あいう映"
        )
    }

    func testJapanesePunctuationStaysOnAllowedSideOfLine() {
        for text in ["あいうえ、かきくけ。さしすせ", "あいう「えおかき」くけこ", "あいう（えおかき）くけこ"] {
            for columns in 3...7 {
                let lines = renderedLines(text, columns: columns)
                XCTAssertGreaterThan(lines.count, 1)
                XCTAssertEqual(lines.joined(), text)
                for line in lines {
                    XCTAssertFalse("、。）」".contains(line.first!), line)
                    XCTAssertFalse("（「".contains(line.last!), line)
                }
            }
        }
    }

    func testJapaneseSmallKanaAndProlongedSoundMarkDoNotStartLines() {
        for text in ["あいうきゃくです", "あいうきゅうです", "あいうちょっとです", "あいうコーヒーです"] {
            for columns in 3...6 {
                let lines = renderedLines(text, columns: columns)
                XCTAssertEqual(lines.joined(), text)
                for line in lines {
                    XCTAssertFalse("ゃゅょっー".contains(line.first!), line)
                }
            }
        }
    }

    func testVisibleRubyPreservesAnnotationAndPunctuationRules() {
        let document = StudyRubyDocument(segments: [
            .text("あいう"), .ruby(base: "映画", reading: "えいが"), .text("。かきくけこ"),
        ])
        let attributed = attributedText(document)
        let ruby = attributed.attribute(
            NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
            at: 3,
            effectiveRange: nil
        )
        XCTAssertNotNil(ruby)
        for columns in 4...8 {
            let lines = renderedLines(attributed, columns: columns)
            XCTAssertEqual(lines.joined(), document.plainText)
            XCTAssertFalse(lines.contains { $0.hasPrefix("。") })
        }
    }

    func testMixedEnglishWordsKeepNormalWordBoundaries() {
        let lines = renderedLines("映画を watching today", columns: 8)
        XCTAssertTrue(lines.contains { $0.contains("watching") })
        XCTAssertEqual(lines.joined(), "映画を watching today")
    }

    private func attributedText(_ document: StudyRubyDocument) -> NSAttributedString {
        document.attributedString(pointSize: 24, weight: .regular, color: .label, alignment: .left)
    }

    private func renderedLines(
        _ text: String,
        columns: Int,
        knownKanji: Set<Character> = []
    ) -> [String] {
        renderedLines(attributedText(StudyRubyDocument.parse(text, knownKanji: knownKanji)), columns: columns)
    }

    private func renderedLines(_ attributed: NSAttributedString, columns: Int) -> [String] {
        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as! UIFont
        let characterWidth = ("あ" as NSString).size(withAttributes: [.font: font]).width
        let view = UITextView(frame: CGRect(x: 0, y: 0, width: characterWidth * CGFloat(columns) + 0.1, height: 1000))
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        let delegate = StudyRubyLineBreakDelegate()
        delegate.updateRubyRanges(in: attributed)
        view.textLayoutManager?.delegate = delegate
        view.attributedText = attributed
        return withExtendedLifetime(delegate) {
            let manager = view.textLayoutManager!
            manager.ensureLayout(for: manager.documentRange)
            var lines: [String] = []
            manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
                for line in fragment.textLineFragments where line.characterRange.length > 0 {
                    lines.append(line.attributedString.attributedSubstring(from: line.characterRange).string)
                }
                return true
            }
            return lines
        }
    }
}

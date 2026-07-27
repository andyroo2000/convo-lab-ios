import XCTest
import UIKit
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
            "経験[けいけん]",
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

        XCTAssertNotEqual(
            renderedPNG(for: rubyText),
            renderedPNG(for: plainText),
            "The TextKit 2 view must draw the ruby glyphs, not merely retain their attribute."
        )
    }

    private func renderedPNG(for text: NSAttributedString) -> Data? {
        let view = UITextView(usingTextLayoutManager: true)
        let delegate = StudyRubyLineBreakDelegate()
        delegate.updateRubyRanges(in: text)
        view.textLayoutManager?.delegate = delegate
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        view.backgroundColor = .white
        view.textContainerInset = UIEdgeInsets(top: 48, left: 0, bottom: 0, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.attributedText = text
        view.layoutIfNeeded()

        return UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            view.layer.render(in: context.cgContext)
        }.pngData()
    }
}

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
        let textStorage = NSTextStorage(attributedString: document.attributedString(
            pointSize: 38,
            weight: .semibold,
            color: .label,
            alignment: .center
        ))
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let delegate = StudyRubyLineBreakDelegate()

        XCTAssertFalse(delegate.layoutManager(
            layoutManager,
            shouldBreakLineByWordBeforeCharacterAt: 1
        ))
        XCTAssertTrue(delegate.layoutManager(
            layoutManager,
            shouldBreakLineByWordBeforeCharacterAt: 2
        ))
        XCTAssertFalse(delegate.layoutManager(
            layoutManager,
            shouldBreakLineByWordBeforeCharacterAt: 3
        ))
    }
}

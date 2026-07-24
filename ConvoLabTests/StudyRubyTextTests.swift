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

    func testIterationMarkDoesNotPreventKnownWordFromHidingItsReading() {
        let document = StudyRubyDocument.parse(
            "時々[ときどき]",
            knownKanji: ["時"]
        )

        XCTAssertEqual(document.segments, [.text("時々")])
    }
}

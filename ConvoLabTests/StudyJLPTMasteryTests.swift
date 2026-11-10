import XCTest
@testable import ConvoLab

@MainActor
final class StudyJLPTMasteryTests: XCTestCase {
    func testAllFiveLevelsDecodeAndSurviveCachedOverviewRoundTrip() throws {
        let metric: [String: Int] = ["masteryPercent": 12, "known": 10, "matched": 20, "covered": 20, "total": 130]
        let band = ["vocabulary": metric, "grammar": metric]
        let levels = Dictionary(uniqueKeysWithValues: ["N5", "N4", "N3", "N2", "N1"].map { ($0, band) })
        let payload: [String: Any] = ["dueCount": 0, "newCount": 0, "reviewCount": 0, "newCardsPerDay": 20, "jlptMastery": levels]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let overview = try JSONDecoder().decode(StudyOverview.self, from: data)
        let mastery = try XCTUnwrap(overview.jlptMastery)
        XCTAssertEqual(mastery.n3?.vocabulary.known, 10)
        XCTAssertEqual(mastery.n2?.grammar.total, 130)
        XCTAssertEqual(mastery.n1?.grammar.masteryPercent, 12)
        let restored = try JSONDecoder().decode(StudyOverview.self, from: JSONEncoder().encode(overview))
        XCTAssertEqual(restored.jlptMastery, mastery)
    }

    func testLegacyN5OnlyPayloadLeavesHigherLevelsAbsent() throws {
        let data = Data(#"{"N5":{"vocabulary":{"masteryPercent":0,"covered":0,"total":684},"grammar":{"masteryPercent":0,"covered":0,"total":77}}}"#.utf8)
        let mastery = try JSONDecoder().decode(StudyJLPTMastery.self, from: data)
        XCTAssertEqual(mastery.n5.vocabulary.total, 684)
        XCTAssertNil(mastery.n4)
        XCTAssertNil(mastery.n3)
        XCTAssertNil(mastery.n2)
        XCTAssertNil(mastery.n1)
    }
}

import Foundation
import XCTest
@testable import ConvoLab

final class StudyCardPlacementTests: XCTestCase {
    @MainActor
    func testClearingSourceEncodesExplicitNullAndPriorityEncodesFalse() throws {
        let source = try JSONEncoder().encode(StudyCardSourceAssignment(cardIds: ["card"], bookSource: nil))
        let sourceBody = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        XCTAssertTrue(sourceBody["bookSource"] is NSNull)
        XCTAssertEqual(sourceBody["cardIds"] as? [String], ["card"])
        let priority = try JSONEncoder().encode(StudyLearnSoonAssignment(cardIds: ["card"], learnSoon: false))
        let priorityBody = try XCTUnwrap(JSONSerialization.jsonObject(with: priority) as? [String: Any])
        XCTAssertEqual(priorityBody["learnSoon"] as? Bool, false)
        XCTAssertNil(priorityBody["bookSource"])
    }

    @MainActor
    func testCreationSourceAndPrioritySurviveOutboxRoundTrip() throws {
        var draft = StudyCardDraft(cardType: .recognition)
        draft.bookSource = StudyBookSource(pileId: "book", chapterId: "chapter", position: 21, reference: "p. 80")
        draft.learnSoon = true
        let creation = StudyCardEditorProjection.creating(draft, id: "card", at: Date())
        let restored = try JSONDecoder().decode(CreateStudyCardRequest.self, from: JSONEncoder().encode(creation.request))
        XCTAssertEqual(restored.bookSource, draft.bookSource)
        XCTAssertEqual(restored.learnSoon, true)
        XCTAssertEqual(restored.id, "card")
    }

    @MainActor
    func testLegacyOutboxRequestsDecodeWithoutSourceMetadata() throws {
        let data = Data(#"{"id":"card","cardType":"recognition","prompt":{},"answer":{}}"#.utf8)
        let request = try JSONDecoder().decode(CreateStudyCardRequest.self, from: data)
        XCTAssertNil(request.bookSource)
        XCTAssertNil(request.learnSoon)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(encoded["bookSource"])
        XCTAssertNil(encoded["learnSoon"])
    }
}

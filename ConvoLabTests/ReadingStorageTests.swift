import XCTest
@testable import ConvoLab

final class ReadingStorageTests: XCTestCase {
    @MainActor
    func testPendingPositionSurvivesRelaunchAndIsScopedToAccount() throws {
        let owner = -301
        let other = -302
        defer {
            try? ReadingLocalStorage.remove(userID: owner)
            try? ReadingLocalStorage.remove(userID: other)
        }
        try ReadingLocalStorage.remove(userID: owner)
        try ReadingLocalStorage.remove(userID: other)
        let position = ReadingPosition(readingId: "reading", pageNumber: 24, sentenceIndex: nil,
                                       readingRevision: 3, eventId: UUID().uuidString, readAt: Date())
        var snapshot = ReadingSnapshot()
        snapshot.pending["reading"] = position
        snapshot.positions["reading"] = position
        let storage = ReadingLocalStorage(userID: owner)
        try storage.save(snapshot)
        XCTAssertEqual(try storage.load().pending["reading"]?.eventId, position.eventId)
        XCTAssertTrue(try ReadingLocalStorage(userID: other).load().pending.isEmpty)
        let data = try JSONEncoder().encode(position)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["sentenceIndex"] is NSNull)
        try storage.saveResource(Data("private audio".utf8), key: "voice-one")
        XCTAssertEqual(try storage.resource(key: "voice-one"), Data("private audio".utf8))
        XCTAssertNil(try storage.resource(key: "voice-two"))
        try ReadingLocalStorage.remove(userID: owner)
        XCTAssertTrue(try storage.load().pending.isEmpty)
        XCTAssertNil(try storage.resource(key: "voice-one"))
    }

    @MainActor
    func testNewerPositionOrderingMatchesServerTieBreak() {
        let date = Date(timeIntervalSince1970: 1000)
        let first = ReadingPosition(readingId: "reading", pageNumber: 24, sentenceIndex: 0,
                                   readingRevision: 1, eventId: "aaaaaaaa", readAt: date)
        let second = ReadingPosition(readingId: "reading", pageNumber: 25, sentenceIndex: nil,
                                    readingRevision: 1, eventId: "BBBBBBBB", readAt: date)
        XCTAssertTrue(second.isNewer(than: first))
        XCTAssertFalse(first.isNewer(than: second))
        XCTAssertFalse(first.isNewer(than: first))
    }
}

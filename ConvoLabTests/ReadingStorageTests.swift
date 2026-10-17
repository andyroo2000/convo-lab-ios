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
    func testDamagedDocumentCachePreservesIndependentPendingPositions() throws {
        let owner = -303
        defer { try? ReadingLocalStorage.remove(userID: owner) }
        try ReadingLocalStorage.remove(userID: owner)
        let storage = ReadingLocalStorage(userID: owner)
        let position = ReadingPosition(readingId: "reading", pageNumber: 24, sentenceIndex: nil,
                                       readingRevision: 1, eventId: UUID().uuidString, readAt: Date())
        var snapshot = ReadingSnapshot()
        snapshot.pending["reading"] = position
        try storage.save(snapshot)
        let directory = URL.applicationSupportDirectory.appending(path: "Readings/\(owner)")
        let cache = directory.appending(path: "library.json")
        try Data("damaged document cache".utf8).write(to: cache)
        let restored = try storage.load()
        XCTAssertEqual(restored.pending["reading"]?.eventId, position.eventId)
        try storage.savePositions(restored)
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "damaged document cache")
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("library.json.recovery-") })
    }

    @MainActor
    func testDamagedPositionFileRetainsValidLibraryAndRecoveryCopy() throws {
        let owner = -304
        defer { try? ReadingLocalStorage.remove(userID: owner) }
        try ReadingLocalStorage.remove(userID: owner)
        let storage = ReadingLocalStorage(userID: owner)
        var snapshot = ReadingSnapshot()
        snapshot.library[1] = ReadingLibraryPage(data: [.init(id: "story", title: "Story", kind: "reading")], currentPage: 1, lastPage: 1)
        try storage.save(snapshot)
        let directory = URL.applicationSupportDirectory.appending(path: "Readings/\(owner)")
        try Data("damaged position file".utf8).write(to: directory.appending(path: "positions.json"))
        XCTAssertEqual(try storage.load().library[1]?.data.first?.id, "story")
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("positions.json.recovery-") })
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

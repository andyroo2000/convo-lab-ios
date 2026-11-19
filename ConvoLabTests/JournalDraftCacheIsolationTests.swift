import XCTest
@testable import ConvoLab

@MainActor
final class JournalDraftCacheIsolationTests: XCTestCase {
    func testNarratorMetadataDoesNotBecomeAnUnreadableDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = JournalDraftStorage(userID: 1, root: root)
        let draft = JournalDraft.new()
        try storage.save(draft)
        let snapshot = storage.directory.appendingPathComponent("narrator-\(draft.id).json")
        await JournalNarratorSnapshot.shared.write(
            .init(analysisID: "analysis", revision: 1, voices: [], selected: "yua"), to: snapshot
        )
        let original = try Data(contentsOf: snapshot)
        let listing = try storage.list()
        XCTAssertEqual(listing.drafts, [draft])
        XCTAssertEqual(listing.unreadableCount, 0)
        XCTAssertEqual(try Data(contentsOf: snapshot), original)
        let api = APIClient(baseURL: URL(string: "https://journal.test")!)
        let store = JournalStore(api: api, userID: 1, storageRoot: root)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.drafts, [draft])
        // Genuine draft damage must still be reported even beside a valid narrator cache.
        try Data("unreadable writing".utf8).write(to: storage.directory.appendingPathComponent(draft.id + ".json"))
        store.refreshDrafts()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try storage.list().unreadableCount, 1)
        XCTAssertEqual(try Data(contentsOf: snapshot), original)
    }
}

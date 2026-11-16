import XCTest
@testable import ConvoLab

final class JournalVersionPreferenceTests: XCTestCase {
    @MainActor
    func testSelectionIsScopedToOwnerAndEntryAndSurvivesReopening() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let key = JournalVersion.preferenceKey(owner: "1", entry: "ABC")
        defer { defaults.removeObject(forKey: key) }
        XCTAssertNil(defaults.string(forKey: key))
        defaults.set(JournalVersion.draft.rawValue, forKey: key)
        XCTAssertEqual(JournalVersion(rawValue: try XCTUnwrap(defaults.string(forKey: key))), .draft)
        XCTAssertNil(defaults.string(forKey: JournalVersion.preferenceKey(owner: "2", entry: "ABC")))
        XCTAssertNil(defaults.string(forKey: JournalVersion.preferenceKey(owner: "1", entry: "DEF")))
        XCTAssertEqual(key, JournalVersion.preferenceKey(owner: "1", entry: "abc"))
    }
}

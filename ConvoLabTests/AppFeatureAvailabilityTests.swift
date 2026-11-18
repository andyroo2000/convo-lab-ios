import XCTest
@testable import ConvoLab

final class AppFeatureAvailabilityTests: XCTestCase {
    func testJournalOnlyDefaultsKeepSettingsAccessible() {
        XCTAssertEqual(AppFeatureFlags.journalOnly.modes, [.journal, .settings])
    }

    func testEachSwitchControlsItsOwnDestinations() {
        let study = AppFeatureFlags(flashcardsEnabled: true, readingsEnabled: false, studyTimeEnabled: false)
        XCTAssertEqual(study.modes, [.journal, .settings, .study, .cards, .dailyAudio])
        let readingAndTime = AppFeatureFlags(flashcardsEnabled: false, readingsEnabled: true, studyTimeEnabled: true)
        XCTAssertEqual(readingAndTime.modes, [.journal, .settings, .readings, .time])
    }

    func testEffectiveAdminFlagsAllowAllModes() throws {
        let data = Data(#"{"flashcardsEnabled":true,"readingsEnabled":true,"studyTimeEnabled":true}"#.utf8)
        let flags = try JSONDecoder().decode(AppFeatureFlags.self, from: data)
        XCTAssertEqual(flags.modes, Set(AppMode.allCases))
    }
}

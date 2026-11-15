import XCTest
@testable import ConvoLab

@MainActor
final class JournalPlaybackActionTests: XCTestCase {
    func testPlaybackActionFollowsTheActualMediaState() {
        XCTAssertEqual(JournalPlaybackAction.current(preparing: false, playing: false, position: 0, duration: 0), .listen)
        XCTAssertEqual(JournalPlaybackAction.current(preparing: true, playing: false, position: 0, duration: 0), .loading)
        XCTAssertEqual(JournalPlaybackAction.current(preparing: false, playing: true, position: 3, duration: 10), .pause)
        XCTAssertEqual(JournalPlaybackAction.current(preparing: false, playing: false, position: 3, duration: 10), .resume)
        XCTAssertEqual(JournalPlaybackAction.current(preparing: false, playing: false, position: 10, duration: 10), .replay)
        XCTAssertEqual(JournalPlaybackAction.current(preparing: false, playing: true, position: 0, duration: 10), .pause)
    }
}

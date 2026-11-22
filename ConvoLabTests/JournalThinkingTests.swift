import XCTest
@testable import ConvoLab

final class JournalThinkingTests: XCTestCase {
    @MainActor
    func testEveryDesktopIllustrationIsBundledAndCropped() {
        XCTAssertEqual(JournalThinkingIllustrations.images.count, 40)
        XCTAssertTrue(JournalThinkingIllustrations.images.allSatisfy { $0.size.width > 0 && $0.size.height > 0 })
    }

    func testIllustrationsChangeInStaggeredSlotsWithoutDisappearingTogether() {
        XCTAssertEqual(JournalThinkingTiming.frame(elapsed: 3.1, slot: 0).turn, 1)
        XCTAssertEqual(JournalThinkingTiming.frame(elapsed: 3.1, slot: 1).turn, 0)
        XCTAssertEqual(JournalThinkingTiming.frame(elapsed: 9.1, slot: 2).turn, 1)
        for time in stride(from: 1.0, through: 90, by: 0.1) {
            let opacities = (0..<3).map { JournalThinkingTiming.frame(elapsed: time, slot: $0).opacity }
            XCTAssertGreaterThan(opacities.max() ?? 0, 0.5)
            XCTAssertTrue(opacities.allSatisfy { (0...1).contains($0) })
        }
    }

    @MainActor
    func testWaitingPhrasesDoNotRepeatConsecutively() {
        var previous = JournalThinkingPhrases.next().english
        for _ in 0..<40 {
            let next = JournalThinkingPhrases.next().english
            XCTAssertNotEqual(previous, next)
            previous = next
        }
    }
}

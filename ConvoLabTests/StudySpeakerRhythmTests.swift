import XCTest
@testable import ConvoLab

@MainActor
final class StudySpeakerRhythmTests: XCTestCase {
    func testSelectedRhythmUsesDiscreteCumulativeWaves() {
        let samples: [(Double, Int)] = [
            (0, 0), (0.799, 0), (0.8, 1), (1.199, 1),
            (1.2, 2), (1.599, 2), (1.6, 3), (2.559, 3), (2.56, 0),
        ]
        for (elapsed, expected) in samples {
            XCTAssertEqual(StudySpeakerRhythm.waveCount(at: elapsed), expected,
                           "Unexpected frame at \(elapsed) seconds")
        }
    }

    func testRhythmRepeatsAndClampsNegativeElapsedTime() {
        XCTAssertEqual(StudySpeakerRhythm.waveCount(at: -1), 0)
        for cycle in 1...3 {
            let start = Double(cycle) * StudySpeakerRhythm.duration
            XCTAssertEqual(StudySpeakerRhythm.waveCount(at: start + 0.4), 0)
            XCTAssertEqual(StudySpeakerRhythm.waveCount(at: start + 1), 1)
            XCTAssertEqual(StudySpeakerRhythm.waveCount(at: start + 1.4), 2)
            XCTAssertEqual(StudySpeakerRhythm.waveCount(at: start + 2), 3)
        }
    }
}

import Foundation

enum StudyMasteryLevel: String, CaseIterable, Sendable {
    case apprentice
    case guru
    case master
    case enlightened
    case burned

    var rank: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

extension StudyCard {
    var fsrsStability: Double? {
        guard case let .number(value) = state.scheduler?["stability"] else { return nil }
        return value
    }

    var effectiveMasteryLevel: StudyMasteryLevel {
        if ["new", "learning", "relearning"].contains(state.queueState) {
            return .apprentice
        }
        if let masteryLevel, let level = StudyMasteryLevel(rawValue: masteryLevel) {
            return level
        }
        let stability = fsrsStability ?? 0
        switch stability {
        case 365...: return .burned
        case 90...: return .enlightened
        case 30...: return .master
        case 7...: return .guru
        default: return .apprentice
        }
    }
}

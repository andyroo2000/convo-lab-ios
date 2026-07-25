import Foundation

struct FSRSReviewSchedule: Equatable, Sendable {
    let dueAt: Date
    let queueState: String
    let schedulerState: JSONValue
    let intervalLabel: String
}

enum FSRSReviewScheduler {
    // Defaults from ts-fsrs 5.3.3 (FSRS-6), with fuzzing disabled for
    // deterministic parity between learning-os and offline clients.
    private static let weights = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194,
        0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629,
        1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]
    private static let requestRetention = 0.9
    private static let maximumIntervalDays = 36_500
    private static let minimumStability = 0.001
    private static let learningSteps = [1, 10]
    private static let relearningSteps = [10]

    private enum CardState: Int {
        case new = 0
        case learning = 1
        case review = 2
        case relearning = 3

        init(queueState: String) {
            switch queueState {
            case "new": self = .new
            case "learning": self = .learning
            case "relearning": self = .relearning
            default: self = .review
            }
        }

        var queueState: String {
            switch self {
            case .new: "new"
            case .learning: "learning"
            case .review: "review"
            case .relearning: "relearning"
            }
        }
    }

    private struct State {
        var due: Date
        var stability: Double
        var difficulty: Double
        var elapsedDays: Int
        var scheduledDays: Int
        var learningSteps: Int
        var reps: Int
        var lapses: Int
        var state: CardState
        var lastReview: Date?
    }

    private struct Memory {
        let difficulty: Double
        let stability: Double
    }

    static func schedule(
        schedulerState: JSONValue?,
        queueState: String,
        rating: ReviewRating,
        reviewedAt: Date
    ) -> FSRSReviewSchedule {
        let current = normalizedState(
            schedulerState,
            queueState: queueState,
            reviewedAt: reviewedAt
        )
        let elapsedDays = elapsedDays(
            from: current.lastReview,
            to: reviewedAt,
            state: current.state
        )
        let grade = grade(for: rating)
        var next: State

        switch current.state {
        case .new:
            next = reviewLearningState(
                current,
                grade: grade,
                reviewedAt: reviewedAt,
                elapsedDays: 0,
                forceFreshMemory: true
            )
        case .learning, .relearning:
            next = reviewLearningState(
                current,
                grade: grade,
                reviewedAt: reviewedAt,
                elapsedDays: elapsedDays,
                forceFreshMemory: false
            )
        case .review:
            next = reviewReviewState(
                current,
                grade: grade,
                reviewedAt: reviewedAt,
                elapsedDays: elapsedDays
            )
        }

        next.elapsedDays = elapsedDays
        next.reps = current.reps + 1
        next.lastReview = reviewedAt

        return FSRSReviewSchedule(
            dueAt: next.due,
            queueState: next.state.queueState,
            schedulerState: serialized(next),
            intervalLabel: intervalLabel(dueAt: next.due, reviewedAt: reviewedAt)
        )
    }

    static func intervalLabel(dueAt: Date, reviewedAt: Date) -> String {
        let seconds = max(0, dueAt.timeIntervalSince(reviewedAt))
        if seconds < 60 {
            return "<1m"
        }
        if seconds < 60 * 60 {
            return "<\(Int(ceil(seconds / 60)))m"
        }
        if seconds < 24 * 60 * 60 {
            return "\(Int((seconds / (60 * 60)).rounded()))h"
        }
        if seconds < 30 * 24 * 60 * 60 {
            return "\(Int((seconds / (24 * 60 * 60)).rounded()))d"
        }
        if seconds < 365 * 24 * 60 * 60 {
            return "\(Int((seconds / (30 * 24 * 60 * 60)).rounded()))mo"
        }
        return "\(Int((seconds / (365 * 24 * 60 * 60)).rounded()))y"
    }

    private static func reviewLearningState(
        _ current: State,
        grade: Int,
        reviewedAt: Date,
        elapsedDays: Int,
        forceFreshMemory: Bool
    ) -> State {
        let memory = forceFreshMemory
            ? nextMemoryState(difficulty: 0, stability: 0, elapsedDays: 0, grade: grade)
            : nextMemoryState(
                difficulty: current.difficulty,
                stability: current.stability,
                elapsedDays: elapsedDays,
                grade: grade
            )
        var next = current
        next.difficulty = memory.difficulty
        next.stability = memory.stability
        return applyLearningSteps(
            to: next,
            originalState: current.state,
            currentStep: current.learningSteps,
            grade: grade,
            reviewedAt: reviewedAt
        )
    }

    private static func reviewReviewState(
        _ current: State,
        grade: Int,
        reviewedAt: Date,
        elapsedDays: Int
    ) -> State {
        let retrievability = forgettingCurve(
            elapsedDays: elapsedDays,
            stability: current.stability
        )
        var candidates: [Int: State] = [:]
        for candidateGrade in 1...4 {
            let memory = nextMemoryState(
                difficulty: current.difficulty,
                stability: current.stability,
                elapsedDays: elapsedDays,
                grade: candidateGrade,
                retrievability: retrievability
            )
            var candidate = current
            candidate.difficulty = memory.difficulty
            candidate.stability = memory.stability
            candidates[candidateGrade] = candidate
        }

        let hardDays = min(
            nextInterval(stability: candidates[2]!.stability),
            nextInterval(stability: candidates[3]!.stability)
        )
        let goodDays = max(
            nextInterval(stability: candidates[3]!.stability),
            hardDays + 1
        )
        let easyDays = max(
            nextInterval(stability: candidates[4]!.stability),
            goodDays + 1
        )

        for (candidateGrade, days) in [(2, hardDays), (3, goodDays), (4, easyDays)] {
            var candidate = candidates[candidateGrade]!
            candidate.scheduledDays = days
            candidate.due = reviewedAt.addingTimeInterval(Double(days) * 86_400)
            candidate.learningSteps = 0
            candidate.state = .review
            candidates[candidateGrade] = candidate
        }

        var again = applyLearningSteps(
            to: candidates[1]!,
            originalState: .review,
            currentStep: current.learningSteps,
            grade: 1,
            reviewedAt: reviewedAt
        )
        again.lapses = current.lapses + 1
        candidates[1] = again

        return candidates[grade]!
    }

    private static func applyLearningSteps(
        to nextState: State,
        originalState: CardState,
        currentStep: Int,
        grade: Int,
        reviewedAt: Date
    ) -> State {
        var next = nextState
        if let step = learningStep(
            state: originalState,
            currentStep: currentStep,
            grade: grade
        ) {
            next.learningSteps = step.nextStep
            next.scheduledDays = 0
            switch originalState {
            case .new: next.state = .learning
            case .review: next.state = .relearning
            case .learning, .relearning: next.state = originalState
            }
            next.due = reviewedAt.addingTimeInterval(Double(step.minutes) * 60)
            return next
        }

        let days = nextInterval(stability: next.stability)
        next.learningSteps = 0
        next.scheduledDays = days
        next.state = .review
        next.due = reviewedAt.addingTimeInterval(Double(days) * 86_400)
        return next
    }

    private static func learningStep(
        state: CardState,
        currentStep: Int,
        grade: Int
    ) -> (minutes: Int, nextStep: Int)? {
        let steps = [.review, .relearning].contains(state)
            ? relearningSteps
            : learningSteps
        guard !steps.isEmpty, currentStep < steps.count else { return nil }

        if state == .review {
            return grade == 1 ? (steps[max(0, currentStep)], 0) : nil
        }

        switch grade {
        case 1:
            return (steps[0], 0)
        case 2:
            let minutes = steps.count == 1
                ? Int((Double(steps[0]) * 1.5).rounded())
                : Int((Double(steps[0] + steps[1]) / 2).rounded())
            return (minutes, currentStep)
        case 3:
            guard steps.indices.contains(currentStep + 1) else { return nil }
            return (steps[currentStep + 1], currentStep + 1)
        default:
            return nil
        }
    }

    private static func nextMemoryState(
        difficulty: Double,
        stability: Double,
        elapsedDays: Int,
        grade: Int,
        retrievability suppliedRetrievability: Double? = nil
    ) -> Memory {
        if difficulty == 0, stability == 0 {
            return Memory(
                difficulty: clamp(initialDifficulty(grade: grade), minimum: 1, maximum: 10),
                stability: max(weights[grade - 1], 0.1)
            )
        }

        let retrievability = suppliedRetrievability ?? forgettingCurve(
            elapsedDays: elapsedDays,
            stability: stability
        )
        let nextStability: Double
        if elapsedDays == 0 {
            nextStability = nextShortTermStability(stability: stability, grade: grade)
        } else if grade == 1 {
            let afterFailure = nextForgetStability(
                difficulty: difficulty,
                stability: stability,
                retrievability: retrievability
            )
            let minimumAfterFailure = roundToEight(
                stability / exp(weights[17] * weights[18])
            )
            nextStability = clamp(
                minimumAfterFailure,
                minimum: minimumStability,
                maximum: afterFailure
            )
        } else {
            nextStability = nextRecallStability(
                difficulty: difficulty,
                stability: stability,
                retrievability: retrievability,
                grade: grade
            )
        }

        return Memory(
            difficulty: nextDifficulty(difficulty: difficulty, grade: grade),
            stability: nextStability
        )
    }

    private static func initialDifficulty(grade: Int) -> Double {
        roundToEight(weights[4] - exp(Double(grade - 1) * weights[5]) + 1)
    }

    private static func nextDifficulty(difficulty: Double, grade: Int) -> Double {
        let delta = -weights[6] * Double(grade - 3)
        let dampedDelta = roundToEight(delta * (10 - difficulty) / 9)
        let next = difficulty + dampedDelta
        let reverted = roundToEight(
            weights[7] * initialDifficulty(grade: 4) + (1 - weights[7]) * next
        )
        return clamp(reverted, minimum: 1, maximum: 10)
    }

    private static func nextShortTermStability(stability: Double, grade: Int) -> Double {
        var increase = pow(stability, -weights[19])
            * exp(weights[17] * (Double(grade - 3) + weights[18]))
        if grade >= 2 {
            increase = max(increase, 1)
        }
        return roundToEight(clamp(
            stability * increase,
            minimum: minimumStability,
            maximum: Double(maximumIntervalDays)
        ))
    }

    private static func nextRecallStability(
        difficulty: Double,
        stability: Double,
        retrievability: Double,
        grade: Int
    ) -> Double {
        let hardPenalty = grade == 2 ? weights[15] : 1
        let easyBonus = grade == 4 ? weights[16] : 1
        let next = stability * (
            1
                + exp(weights[8])
                * (11 - difficulty)
                * pow(stability, -weights[9])
                * (exp((1 - retrievability) * weights[10]) - 1)
                * hardPenalty
                * easyBonus
        )
        return roundToEight(clamp(
            next,
            minimum: minimumStability,
            maximum: Double(maximumIntervalDays)
        ))
    }

    private static func nextForgetStability(
        difficulty: Double,
        stability: Double,
        retrievability: Double
    ) -> Double {
        let next = weights[11]
            * pow(difficulty, -weights[12])
            * (pow(stability + 1, weights[13]) - 1)
            * exp((1 - retrievability) * weights[14])
        return roundToEight(clamp(
            next,
            minimum: minimumStability,
            maximum: Double(maximumIntervalDays)
        ))
    }

    private static func forgettingCurve(elapsedDays: Int, stability: Double) -> Double {
        let decay = -weights[20]
        let factor = roundToEight(exp(log(0.9) / decay) - 1)
        return roundToEight(pow(
            1 + factor * Double(elapsedDays) / stability,
            decay
        ))
    }

    private static func nextInterval(stability: Double) -> Int {
        let decay = -weights[20]
        let factor = roundToEight(exp(log(0.9) / decay) - 1)
        let modifier = roundToEight(
            (pow(requestRetention, 1 / decay) - 1) / factor
        )
        return min(
            max(1, Int((stability * modifier).rounded())),
            maximumIntervalDays
        )
    }

    private static func normalizedState(
        _ schedulerState: JSONValue?,
        queueState: String,
        reviewedAt: Date
    ) -> State {
        let object: [String: JSONValue]
        if case let .object(value)? = schedulerState {
            object = value
        } else {
            object = [:]
        }
        let fallbackState = CardState(queueState: queueState)
        let state = integer(object["state"]).flatMap(CardState.init(rawValue:))
            ?? fallbackState
        let isNew = state == .new

        return State(
            due: object["due"]?.stringValue.flatMap(parseDate) ?? reviewedAt,
            stability: isNew
                ? 0
                : max(number(object["stability"]) ?? 0.1, minimumStability),
            difficulty: isNew
                ? 0
                : clamp(number(object["difficulty"]) ?? 5, minimum: 1, maximum: 10),
            elapsedDays: max(0, integer(object["elapsed_days"]) ?? 0),
            scheduledDays: max(0, integer(object["scheduled_days"]) ?? 0),
            learningSteps: max(0, integer(object["learning_steps"]) ?? 0),
            reps: max(0, integer(object["reps"]) ?? 0),
            lapses: max(0, integer(object["lapses"]) ?? 0),
            state: state,
            lastReview: object["last_review"]?.stringValue.flatMap(parseDate)
        )
    }

    private static func serialized(_ state: State) -> JSONValue {
        .object([
            "due": .string(formatDate(state.due)),
            "stability": .number(state.stability),
            "difficulty": .number(state.difficulty),
            "elapsed_days": .number(Double(state.elapsedDays)),
            "scheduled_days": .number(Double(state.scheduledDays)),
            "learning_steps": .number(Double(state.learningSteps)),
            "reps": .number(Double(state.reps)),
            "lapses": .number(Double(state.lapses)),
            "state": .number(Double(state.state.rawValue)),
            "last_review": state.lastReview.map { .string(formatDate($0)) } ?? .null,
        ])
    }

    private static func elapsedDays(
        from lastReview: Date?,
        to reviewedAt: Date,
        state: CardState
    ) -> Int {
        guard state != .new, let lastReview else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let lastDay = calendar.startOfDay(for: lastReview)
        let reviewDay = calendar.startOfDay(for: reviewedAt)
        return max(0, calendar.dateComponents([.day], from: lastDay, to: reviewDay).day ?? 0)
    }

    private static func grade(for rating: ReviewRating) -> Int {
        switch rating {
        case .again: 1
        case .hard: 2
        case .good: 3
        case .easy: 4
        }
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case let .number(number) = value, number.isFinite else { return nil }
        return number
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard let number = number(value), number.rounded() == number else { return nil }
        return Int(number)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func clamp(
        _ value: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        min(max(value, minimum), maximum)
    }

    private static func roundToEight(_ value: Double) -> Double {
        let factor = 100_000_000.0
        return floor(value * factor + 0.5) / factor
    }
}

import XCTest
@testable import ConvoLab

@MainActor
final class StudyReviewSchedulingTests: XCTestCase {
    func testMatureCardRatingsMatchTsFSRSAndLearningOS() throws {
        let reviewedAt = try date("2026-07-25T12:00:00.000Z")
        let expectations: [(
            rating: ReviewRating,
            due: String,
            stability: Double,
            difficulty: Double,
            scheduledDays: Double,
            queueState: String,
            lapses: Double,
            label: String
        )] = [
            (.again, "2026-07-25T12:10:00.000Z", 3.31374859, 9.76073091, 0, "relearning", 2, "<10m"),
            (.hard, "2026-10-17T12:00:00.000Z", 84.27757184, 9.53182114, 84, "review", 1, "84d"),
            (.good, "2026-11-06T12:00:00.000Z", 104.22021241, 9.30291137, 104, "review", 1, "104d"),
            (.easy, "2026-12-20T12:00:00.000Z", 147.89289417, 9.0740016, 148, "review", 1, "148d"),
        ]
        let card = makeCard(queueState: "review", scheduler: matureScheduler)

        for expectation in expectations {
            let schedule = card.reviewSchedule(expectation.rating, at: reviewedAt)
            let reviewed = card.applyingReview(expectation.rating, at: reviewedAt)

            XCTAssertEqual(schedule.dueAt, try date(expectation.due))
            XCTAssertEqual(schedule.queueState, expectation.queueState)
            XCTAssertEqual(schedule.intervalLabel, expectation.label)
            XCTAssertEqual(schedule.schedulerState["stability"], .number(expectation.stability))
            XCTAssertEqual(schedule.schedulerState["difficulty"], .number(expectation.difficulty))
            XCTAssertEqual(
                schedule.schedulerState["scheduled_days"],
                .number(expectation.scheduledDays)
            )
            XCTAssertEqual(schedule.schedulerState["elapsed_days"], .number(163))
            XCTAssertEqual(schedule.schedulerState["reps"], .number(13))
            XCTAssertEqual(schedule.schedulerState["lapses"], .number(expectation.lapses))
            XCTAssertEqual(reviewed.state.dueAt, schedule.dueAt)
            XCTAssertEqual(reviewed.state.scheduler, schedule.schedulerState)
            XCTAssertEqual(
                reviewed.state.failedAt != nil,
                expectation.rating == .again
            )
        }
    }

    func testNewCardRatingsMatchTsFSRSAndLearningOS() throws {
        let reviewedAt = try date("2026-07-25T12:00:00.000Z")
        let card = makeCard(
            queueState: "new",
            scheduler: .object([
                "due": .string("2026-07-25T12:00:00.000Z"),
                // Older learning-os rows seeded non-zero memory for new cards.
                "stability": .number(0.1),
                "difficulty": .number(5),
                "elapsed_days": .number(0),
                "scheduled_days": .number(0),
                "learning_steps": .number(0),
                "reps": .number(0),
                "lapses": .number(0),
                "state": .number(0),
                "last_review": .null,
            ])
        )
        let expectations: [(
            rating: ReviewRating,
            due: String,
            stability: Double,
            difficulty: Double,
            learningSteps: Double,
            scheduledDays: Double,
            queueState: String
        )] = [
            (.again, "2026-07-25T12:01:00.000Z", 0.212, 6.4133, 0, 0, "learning"),
            (.hard, "2026-07-25T12:06:00.000Z", 1.2931, 5.11217071, 0, 0, "learning"),
            (.good, "2026-07-25T12:10:00.000Z", 2.3065, 2.11810397, 1, 0, "learning"),
            (.easy, "2026-08-02T12:00:00.000Z", 8.2956, 1, 0, 8, "review"),
        ]

        for expectation in expectations {
            let reviewed = card.applyingReview(expectation.rating, at: reviewedAt)

            XCTAssertEqual(reviewed.state.dueAt, try date(expectation.due))
            XCTAssertEqual(reviewed.state.queueState, expectation.queueState)
            XCTAssertEqual(reviewed.state.scheduler?["stability"], .number(expectation.stability))
            XCTAssertEqual(reviewed.state.scheduler?["difficulty"], .number(expectation.difficulty))
            XCTAssertEqual(
                reviewed.state.scheduler?["learning_steps"],
                .number(expectation.learningSteps)
            )
            XCTAssertEqual(
                reviewed.state.scheduler?["scheduled_days"],
                .number(expectation.scheduledDays)
            )
            XCTAssertEqual(reviewed.state.introducedAt, reviewedAt)
        }
    }

    func testHardKeepsLearningAndRelearningState() {
        let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let learning = makeCard(
            queueState: "learning",
            scheduler: learningScheduler(state: 1)
        ).applyingReview(.hard, at: reviewedAt)
        let relearning = makeCard(
            queueState: "relearning",
            scheduler: learningScheduler(state: 3)
        ).applyingReview(.hard, at: reviewedAt)

        XCTAssertEqual(learning.state.queueState, "learning")
        XCTAssertEqual(relearning.state.queueState, "relearning")
        XCTAssertEqual(
            learning.state.dueAt,
            reviewedAt.addingTimeInterval(6 * 60)
        )
        XCTAssertEqual(
            relearning.state.dueAt,
            reviewedAt.addingTimeInterval(15 * 60)
        )
    }

    func testHardUsesTheSameSixMinuteDelayAfterAdvancingToTheSecondLearningStep() {
        let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let card = makeCard(
            queueState: "learning",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00.000Z"),
                "stability": .number(2.3065),
                "difficulty": .number(2.11810397),
                "elapsed_days": .number(0),
                "scheduled_days": .number(0),
                "learning_steps": .number(1),
                "reps": .number(1),
                "lapses": .number(0),
                "state": .number(1),
                "last_review": .string("2027-01-15T07:50:00.000Z"),
            ])
        )

        let reviewed = card.applyingReview(.hard, at: reviewedAt)

        XCTAssertEqual(reviewed.state.queueState, "learning")
        XCTAssertEqual(reviewed.state.dueAt, reviewedAt.addingTimeInterval(6 * 60))
        XCTAssertEqual(reviewed.state.scheduler?["learning_steps"], .number(1))
        XCTAssertEqual(reviewed.state.scheduler?["stability"], .number(2.3065))
        XCTAssertEqual(reviewed.state.scheduler?["difficulty"], .number(4.75285849))
    }

    func testElapsedDaysUsesUtcCalendarDays() throws {
        let reviewedAt = try date("2026-07-25T00:01:00.000Z")
        let lastReview = try date("2026-07-24T23:59:00.000Z")
        let card = makeCard(
            queueState: "review",
            scheduler: .object([
                "last_review": .string(format(lastReview)),
                "stability": .number(10),
                "difficulty": .number(5),
                "learning_steps": .number(0),
                "reps": .number(2),
                "lapses": .number(0),
                "state": .number(2),
            ])
        )

        let reviewed = card.applyingReview(.good, at: reviewedAt)

        XCTAssertEqual(reviewed.state.scheduler?["elapsed_days"], .number(1))
    }

    private var matureScheduler: JSONValue {
        .object([
            "due": .string("2026-04-12T00:00:00.000Z"),
            "stability": .number(54.1885),
            "difficulty": .number(9.317),
            "elapsed_days": .number(59),
            "scheduled_days": .number(59),
            "learning_steps": .number(0),
            "reps": .number(12),
            "lapses": .number(1),
            "state": .number(2),
            "last_review": .string("2026-02-12T13:01:42.000Z"),
        ])
    }

    private func learningScheduler(state: Double) -> JSONValue {
        .object([
            "due": .string("2027-01-15T08:00:00.000Z"),
            "stability": .number(state == 1 ? 2.3065 : 5),
            "difficulty": .number(state == 1 ? 4 : 6),
            "elapsed_days": .number(0),
            "scheduled_days": .number(0),
            "learning_steps": .number(0),
            "reps": .number(state == 1 ? 1 : 5),
            "lapses": .number(state == 1 ? 0 : 1),
            "state": .number(state),
            "last_review": .string("2027-01-15T07:50:00.000Z"),
        ])
    }

    private func makeCard(
        queueState: String,
        scheduler: JSONValue
    ) -> StudyCard {
        StudyCard(
            id: "01J00000000000000000000020",
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("復習")]),
            answer: .object(["meaning": .string("review")]),
            state: .init(
                dueAt: .now,
                introducedAt: queueState == "new" ? nil : .now,
                failedAt: nil,
                queueState: queueState,
                scheduler: scheduler,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value))
    }

    private func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

import XCTest
@testable import ConvoLab

@MainActor
final class StudyReviewSchedulingTests: XCTestCase {
    func testReviewRatingsMatchLearningOSStarterSchedule() throws {
        let reviewedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-24T12:00:00Z")
        )
        let expectations: [(ReviewRating, TimeInterval, String, Bool)] = [
            (.again, 10 * 60, "relearning", true),
            (.hard, 24 * 60 * 60, "review", false),
            (.good, 3 * 24 * 60 * 60, "review", false),
            (.easy, 7 * 24 * 60 * 60, "review", false),
        ]

        for (rating, interval, queueState, isFailed) in expectations {
            let reviewed = makeCard(queueState: "review").applyingReview(
                rating,
                at: reviewedAt
            )

            XCTAssertEqual(reviewed.state.dueAt, reviewedAt.addingTimeInterval(interval))
            XCTAssertEqual(reviewed.state.queueState, queueState)
            XCTAssertEqual(reviewed.state.failedAt != nil, isFailed)
            XCTAssertEqual(reviewed.state.scheduler?["reps"], .number(3))
            XCTAssertEqual(
                reviewed.state.scheduler?["lapses"],
                .number(rating == .again ? 2 : 1)
            )
        }
    }

    func testHardKeepsNewAndRelearningCardsInLearning() {
        let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)

        for queueState in ["new", "learning", "relearning"] {
            let reviewed = makeCard(queueState: queueState).applyingReview(
                .hard,
                at: reviewedAt
            )
            XCTAssertEqual(reviewed.state.queueState, "learning")
        }
    }

    func testFirstReviewIntroducesNewCard() {
        let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let reviewed = makeCard(queueState: "new").applyingReview(
            .good,
            at: reviewedAt
        )

        XCTAssertEqual(reviewed.state.introducedAt, reviewedAt)
    }

    func testSchedulerStateUsesBackendRoundingAndNumericDefaults() {
        let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let card = makeCard(
            queueState: "review",
            scheduler: .object([
                "last_review": .string(
                    reviewedAt.addingTimeInterval(-36 * 60 * 60).studyTestISO8601
                ),
                "stability": .null,
                "difficulty": .string("invalid"),
                "learning_steps": .null,
            ])
        )

        let reviewed = card.applyingReview(.hard, at: reviewedAt)

        XCTAssertEqual(reviewed.state.scheduler?["elapsed_days"], .number(2))
        XCTAssertEqual(reviewed.state.scheduler?["scheduled_days"], .number(1))
        XCTAssertEqual(reviewed.state.scheduler?["stability"], .number(0.1))
        XCTAssertEqual(reviewed.state.scheduler?["difficulty"], .number(5))
        XCTAssertEqual(reviewed.state.scheduler?["learning_steps"], .number(0))
    }

    private func makeCard(
        queueState: String,
        scheduler: JSONValue = .object([
            "reps": .number(2),
            "lapses": .number(1),
        ])
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
}

private extension Date {
    var studyTestISO8601: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }
}

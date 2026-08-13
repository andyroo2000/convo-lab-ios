import CryptoKit
import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class FSRSGoldenFixtureTests: XCTestCase {
    private static let canonicalAPICommit = "4abf8e7b4d0bda8982dbeff0da0924a6859d6d5b"
    private static let canonicalSHA256 = "fc12eadad5f1677e6d07fb349ca26299e1c28a24b721676a6ff6896d0805ef6a"
    private static let stateFields = [
        "due", "stability", "difficulty", "elapsed_days", "scheduled_days",
        "learning_steps", "reps", "lapses", "state", "last_review",
    ]

    func testVendoredFixtureMatchesCanonicalAPIArtifact() throws {
        let fixtureData = try fixtureData()
        let digest = SHA256.hash(data: fixtureData).map { String(format: "%02x", $0) }.joined()
        let checksum = try String(contentsOf: fixtureURL(extension: "sha256"), encoding: .utf8)
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init)

        XCTAssertEqual(Self.canonicalAPICommit.count, 40)
        XCTAssertEqual(digest, Self.canonicalSHA256)
        XCTAssertEqual(checksum, Self.canonicalSHA256)
        XCTAssertNil(
            Bundle.main.url(forResource: "fsrs-golden-v1", withExtension: "json"),
            "The canonical fixture belongs in the test bundle, not the app runtime bundle."
        )
        try assertIntegerTokensAreNotCoerced(in: fixtureData)
    }

    func testProfileMatchesRuntimeConstants() throws {
        let fixture = try fixture()

        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.contract.schedulerStateFields, Self.stateFields)
        XCTAssertEqual(fixture.profile.runtimeProfile, FSRSReviewScheduler.profile)
        XCTAssertEqual(fixture.comparison.floatAbsoluteTolerance, 0.000_000_01)
        XCTAssertEqual(fixture.provenance.canonicalRepository, "andyroo2000/learning-os")
        XCTAssertEqual(fixture.provenance.canonicalPath, "tests/Fixtures/fsrs-golden-v1.json")
    }

    func testSchedulingCasesMatchCanonicalFixture() throws {
        let fixture = try fixture()

        for vector in fixture.schedulingCases {
            let reviewedAt = try XCTUnwrap(
                ISO8601Milliseconds.date(from: vector.input.reviewedAt),
                vector.id
            )
            let rating = try XCTUnwrap(ReviewRating(rawValue: vector.input.rating), vector.id)
            let schedule = try FSRSReviewScheduler.schedule(
                schedulerState: vector.input.schedulerState?.jsonValue,
                queueState: vector.input.studyStatus,
                rating: rating,
                reviewedAt: reviewedAt
            )

            XCTAssertEqual(schedule.queueState, vector.expected.studyStatus, vector.id)
            XCTAssertEqual(
                schedule.dueAt,
                try XCTUnwrap(ISO8601Milliseconds.date(from: vector.expected.dueAt)),
                vector.id
            )
            try assertSchedulerState(
                schedule.schedulerState,
                equals: vector.expected.schedulerState,
                fields: fixture.contract.schedulerStateFields,
                tolerance: fixture.comparison.floatAbsoluteTolerance,
                caseID: vector.id
            )
        }
    }

    func testTransportNormalizationCasesMatchCanonicalFixture() throws {
        for vector in try fixture().transportNormalizationCases {
            let parsed = ISO8601Milliseconds.date(from: vector.input.timestamp)

            XCTAssertEqual(parsed != nil, vector.expected.accepted, vector.id)
            XCTAssertEqual(
                parsed.map(ISO8601Milliseconds.string),
                vector.expected.canonicalUTC,
                vector.id
            )
        }
    }

    func testStrictOffsetBoundariesMatchAPIContract() {
        let accepted = [
            "2026-05-27T09:15:00.000Z",
            "2026-05-27T09:15:00.000+00:00",
            "2026-05-27T09:15:00.000+05:30",
            "2026-05-27T09:15:00.000+14:00",
            "2026-05-27T09:15:00.000-12:00",
        ]
        let rejected = [
            "2026-05-27T09:15:00.000+14:01",
            "2026-05-27T09:15:00.000-12:01",
            "2026-05-27T09:15:00.000+05:60",
            "2026-05-27T09:15:00.000-05:60",
            "2026-05-27T09:15:00.000+99:00",
            "2026-05-27T09:15:00.000-99:00",
        ]

        accepted.forEach {
            XCTAssertNotNil(ISO8601Milliseconds.date(from: $0), $0)
        }
        rejected.forEach {
            XCTAssertNil(ISO8601Milliseconds.date(from: $0), $0)
        }
    }

    private func assertSchedulerState(
        _ actual: JSONValue,
        equals expected: GoldenFixture.SchedulerState,
        fields: [String],
        tolerance: Double,
        caseID: String
    ) throws {
        guard case let .object(actualObject) = actual,
              case let .object(expectedObject) = expected.jsonValue
        else {
            return XCTFail("\(caseID): scheduler state must be an object")
        }
        XCTAssertEqual(Set(actualObject.keys), Set(fields), caseID)
        XCTAssertEqual(Set(expectedObject.keys), Set(fields), caseID)
        for field in fields {
            switch field {
            case "stability", "difficulty":
                guard case let .number(actualNumber)? = actualObject[field],
                      case let .number(expectedNumber)? = expectedObject[field]
                else {
                    XCTFail("\(caseID).\(field): expected numbers")
                    continue
                }
                XCTAssertEqual(actualNumber, expectedNumber, accuracy: tolerance, "\(caseID).\(field)")
            case "due", "last_review":
                guard case let .string(actualTimestamp)? = actualObject[field],
                      case let .string(expectedTimestamp)? = expectedObject[field]
                else {
                    XCTFail("\(caseID).\(field): expected timestamps")
                    continue
                }
                let actualDate = try XCTUnwrap(
                    ISO8601Milliseconds.date(from: actualTimestamp),
                    "\(caseID).\(field): invalid actual timestamp"
                )
                let expectedDate = try XCTUnwrap(
                    ISO8601Milliseconds.date(from: expectedTimestamp),
                    "\(caseID).\(field): invalid expected timestamp"
                )
                XCTAssertEqual(actualDate, expectedDate, "\(caseID).\(field)")
            case "elapsed_days", "scheduled_days", "learning_steps", "reps", "lapses", "state":
                guard case let .number(actualNumber)? = actualObject[field],
                      case let .number(expectedNumber)? = expectedObject[field]
                else {
                    XCTFail("\(caseID).\(field): expected integers")
                    continue
                }
                XCTAssertEqual(actualNumber.rounded(), actualNumber, "\(caseID).\(field)")
                XCTAssertEqual(expectedNumber.rounded(), expectedNumber, "\(caseID).\(field)")
                XCTAssertEqual(actualNumber, expectedNumber, "\(caseID).\(field)")
            default:
                XCTAssertEqual(actualObject[field], expectedObject[field], "\(caseID).\(field)")
            }
        }
    }

    private func fixture() throws -> GoldenFixture {
        try JSONDecoder().decode(GoldenFixture.self, from: fixtureData())
    }

    private func fixtureData() throws -> Data {
        try Data(contentsOf: fixtureURL(extension: "json"))
    }

    private func fixtureURL(extension fileExtension: String) throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "fsrs-golden-v1",
                withExtension: fileExtension
            )
        )
    }

    private func assertIntegerTokensAreNotCoerced(in data: Data) throws {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        assertIntegerToken(root["schema_version"], path: "schema_version")

        let profile = try XCTUnwrap(root["profile"] as? [String: Any])
        assertIntegerToken(
            profile["maximum_interval_days"],
            path: "profile.maximum_interval_days"
        )
        for key in ["learning_steps_minutes", "relearning_steps_minutes"] {
            for (index, value) in try XCTUnwrap(profile[key] as? [Any]).enumerated() {
                assertIntegerToken(value, path: "profile.\(key)[\(index)]")
            }
        }

        let cases = try XCTUnwrap(root["scheduling_cases"] as? [[String: Any]])
        let integerFields = [
            "elapsed_days", "scheduled_days", "learning_steps", "reps", "lapses", "state",
        ]
        for vector in cases {
            let id = try XCTUnwrap(vector["id"] as? String)
            let input = try XCTUnwrap(vector["input"] as? [String: Any])
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            let states = [
                ("input", input["scheduler_state"] as? [String: Any]),
                ("expected", expected["scheduler_state"] as? [String: Any]),
            ]
            for (kind, state) in states {
                guard let state else { continue }
                for field in integerFields where state[field] != nil {
                    assertIntegerToken(
                        state[field],
                        path: "scheduling_cases.\(id).\(kind).scheduler_state.\(field)"
                    )
                }
            }
        }
    }

    private func assertIntegerToken(_ value: Any?, path: String) {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["d", "f"].contains(String(cString: number.objCType))
        else {
            return XCTFail("\(path) must use an integer JSON token")
        }
    }
}

private struct GoldenFixture: Decodable {
    let schemaVersion: Int
    let contract: Contract
    let profile: Profile
    let comparison: Comparison
    let provenance: Provenance
    let schedulingCases: [SchedulingCase]
    let transportNormalizationCases: [TransportCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case contract, profile, comparison, provenance
        case schedulingCases = "scheduling_cases"
        case transportNormalizationCases = "transport_normalization_cases"
    }

    struct Contract: Decodable {
        let schedulerStateFields: [String]

        enum CodingKeys: String, CodingKey {
            case schedulerStateFields = "scheduler_state_fields"
        }
    }

    struct Profile: Decodable {
        let algorithm: String
        let library: String
        let libraryVersion: String
        let weights: [Double]
        let requestRetention: Double
        let maximumIntervalDays: Int
        let minimumStability: Double
        let learningStepsMinutes: [Int]
        let relearningStepsMinutes: [Int]
        let enableFuzz: Bool
        let enableShortTerm: Bool

        var runtimeProfile: FSRSReviewScheduler.Profile {
            FSRSReviewScheduler.Profile(
                algorithm: algorithm,
                library: library,
                libraryVersion: libraryVersion,
                weights: weights,
                requestRetention: requestRetention,
                maximumIntervalDays: maximumIntervalDays,
                minimumStability: minimumStability,
                learningStepsMinutes: learningStepsMinutes,
                relearningStepsMinutes: relearningStepsMinutes,
                enableFuzz: enableFuzz,
                enableShortTerm: enableShortTerm
            )
        }

        enum CodingKeys: String, CodingKey {
            case algorithm, library, weights
            case libraryVersion = "library_version"
            case requestRetention = "request_retention"
            case maximumIntervalDays = "maximum_interval_days"
            case minimumStability = "minimum_stability"
            case learningStepsMinutes = "learning_steps_minutes"
            case relearningStepsMinutes = "relearning_steps_minutes"
            case enableFuzz = "enable_fuzz"
            case enableShortTerm = "enable_short_term"
        }
    }

    struct Comparison: Decodable {
        let floatAbsoluteTolerance: Double

        enum CodingKeys: String, CodingKey {
            case floatAbsoluteTolerance = "float_absolute_tolerance"
        }
    }

    struct Provenance: Decodable {
        let canonicalRepository: String
        let canonicalPath: String

        enum CodingKeys: String, CodingKey {
            case canonicalRepository = "canonical_repository"
            case canonicalPath = "canonical_path"
        }
    }

    struct SchedulingCase: Decodable {
        let id: String
        let input: SchedulingInput
        let expected: SchedulingExpected
    }

    struct SchedulingInput: Decodable {
        let studyStatus: String
        let rating: String
        let reviewedAt: String
        let schedulerState: SchedulerState?

        enum CodingKeys: String, CodingKey {
            case studyStatus = "study_status"
            case rating
            case reviewedAt = "reviewed_at"
            case schedulerState = "scheduler_state"
        }
    }

    struct SchedulingExpected: Decodable {
        let studyStatus: String
        let dueAt: String
        let schedulerState: SchedulerState

        enum CodingKeys: String, CodingKey {
            case studyStatus = "study_status"
            case dueAt = "due_at"
            case schedulerState = "scheduler_state"
        }
    }

    struct SchedulerState: Decodable {
        let due: String?
        let stability: Double
        let difficulty: Double
        let elapsedDays: Int?
        let scheduledDays: Int?
        let learningSteps: Int
        let reps: Int
        let lapses: Int
        let state: Int
        let lastReview: String?

        var jsonValue: JSONValue {
            var object: [String: JSONValue] = [
                "stability": .number(stability),
                "difficulty": .number(difficulty),
                "learning_steps": .number(Double(learningSteps)),
                "reps": .number(Double(reps)),
                "lapses": .number(Double(lapses)),
                "state": .number(Double(state)),
                "last_review": lastReview.map(JSONValue.string) ?? .null,
            ]
            if let due { object["due"] = .string(due) }
            if let elapsedDays { object["elapsed_days"] = .number(Double(elapsedDays)) }
            if let scheduledDays { object["scheduled_days"] = .number(Double(scheduledDays)) }
            return .object(object)
        }

        enum CodingKeys: String, CodingKey {
            case due, stability, difficulty
            case elapsedDays = "elapsed_days"
            case scheduledDays = "scheduled_days"
            case learningSteps = "learning_steps"
            case reps, lapses, state
            case lastReview = "last_review"
        }
    }

    struct TransportCase: Decodable {
        let id: String
        let input: TransportInput
        let expected: TransportExpected
    }

    struct TransportInput: Decodable {
        let timestamp: String
    }

    struct TransportExpected: Decodable {
        let accepted: Bool
        let canonicalUTC: String?

        enum CodingKeys: String, CodingKey {
            case accepted
            case canonicalUTC = "canonical_utc"
        }
    }
}

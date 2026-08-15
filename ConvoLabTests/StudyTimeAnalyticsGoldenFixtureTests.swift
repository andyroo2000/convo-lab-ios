import CryptoKit
import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeAnalyticsGoldenFixtureTests: XCTestCase {
    private static let canonicalWebCommit = "ee0164e4d51ffdde92844244b71169f079ba154e"
    private static let canonicalSHA256 = "0a5b0ffe6d56e5d80add646d33c84977cbb079355ebd1c9216dc335d85554255"

    func testFixtureIntegrityAndProvenance() throws {
        let data = try fixtureData()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let checksum = try String(contentsOf: fixtureURL(extension: "sha256"), encoding: .utf8)
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init)
        let fixture = try fixture()

        XCTAssertEqual(digest, Self.canonicalSHA256)
        XCTAssertEqual(checksum, Self.canonicalSHA256)
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.provenance.alignedCommit, Self.canonicalWebCommit)
        XCTAssertEqual(fixture.provenance.alignedRepository, "andyroo2000/convo-lab")
        XCTAssertEqual(
            fixture.provenance.alignedPath,
            "client/src/test/fixtures/studyTimeAnalytics.ts"
        )
        XCTAssertEqual(
            Bundle.main.bundleURL.lastPathComponent,
            "ConvoLab.app",
            "This hosted test must inspect the app bundle for the target-membership assertion."
        )
        XCTAssertNil(
            Bundle.main.url(forResource: "study-time-analytics-v1", withExtension: "json"),
            "The correctness matrix belongs in the test bundle, not the app."
        )
    }

    func testFixedAxesCoverTheirCompleteSelectedPeriods() throws {
        let fixture = try fixture()

        for vector in fixture.fixedAxes {
            let range = try fixedRange(vector)
            let projection = StudyTimeAnalyticsProjection(
                analytics: range,
                generatedAt: try date("2026-08-15T16:00:00.000Z"),
                includedCategories: Set(StudyActivityCategory.allCases),
                calendar: try calendar(timeZone: fixture.timeZone)
            )

            XCTAssertEqual(range.buckets.count, vector.bucketCount, vector.id)
            XCTAssertEqual(range.buckets.first?.startsAt, vector.startsAt, vector.id)
            XCTAssertEqual(range.buckets.last?.endsAt, vector.endsAt, vector.id)
            XCTAssertEqual(projection.chartDomain, vector.startsAt...vector.endsAt, vector.id)
            XCTAssertEqual(projection.totalDurationMs, 30 * 60_000, vector.id)
            XCTAssertTrue(
                range.buckets.dropFirst().allSatisfy { projection.duration(for: $0) == 0 },
                vector.id
            )
            assertConservation(projection, caseID: vector.id)
        }
    }

    func testCrossMidnightBucketsAndFiltersConserveTime() throws {
        let fixture = try fixture()
        let vector = fixture.crossMidnight
        let range = makeRange(vector)

        for filter in vector.filters {
            let projection = StudyTimeAnalyticsProjection(
                analytics: range,
                generatedAt: vector.generatedAt,
                includedCategories: Set(filter.included),
                calendar: try calendar(timeZone: fixture.timeZone)
            )

            XCTAssertEqual(projection.totalDurationMs, filter.expectedTotalMs, filter.id)
            XCTAssertEqual(
                range.buckets.map(projection.duration(for:)),
                filter.expectedBucketMs,
                filter.id
            )
            XCTAssertEqual(
                projection.bestBucket?.startsAt,
                filter.expectedTotalMs == 0 ? nil : vector.expectedBestBucketStart,
                filter.id
            )
            assertConservation(projection, caseID: filter.id)
        }
    }

    func testEmptyCurrentCompletedAndDSTProjectionCases() throws {
        let fixture = try fixture()

        for vector in fixture.projectionCases {
            let projection = StudyTimeAnalyticsProjection(
                analytics: makeRange(vector),
                generatedAt: vector.generatedAt,
                includedCategories: Set(vector.included),
                calendar: try calendar(timeZone: fixture.timeZone)
            )

            XCTAssertEqual(
                projection.totalDurationMs,
                vector.expectedTotalMs,
                vector.caseID
            )
            XCTAssertEqual(
                projection.dailyAverageDurationMs,
                vector.expectedDailyAverageMs,
                vector.caseID
            )
            XCTAssertEqual(
                projection.elapsedDayCount,
                vector.expectedElapsedDays,
                vector.caseID
            )
            XCTAssertEqual(
                projection.bestBucket?.startsAt,
                vector.expectedBestBucketStart,
                vector.caseID
            )
            XCTAssertEqual(
                projection.chartDomain,
                vector.startsAt...vector.endsAt,
                vector.caseID
            )
            assertConservation(projection, caseID: vector.caseID)
        }
    }

    private func fixedRange(_ vector: Fixture.FixedAxis) throws -> StudyTimeAnalyticsRange {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let component: Calendar.Component = switch vector.component {
        case "hour": .hour
        case "day": .day
        case "month": .month
        default: throw FixtureError.unsupportedComponent(vector.component)
        }
        var buckets: [StudyTimeAnalyticsBucket] = []
        for index in 0..<vector.bucketCount {
            let start = try XCTUnwrap(
                utc.date(byAdding: component, value: index, to: vector.startsAt)
            )
            let end = try XCTUnwrap(
                utc.date(byAdding: component, value: index + 1, to: vector.startsAt)
            )
            buckets.append(
                StudyTimeAnalyticsBucket(
                    startsAt: start,
                    endsAt: end,
                    totalMs: index == 0 ? 30 * 60_000 : 0,
                    categories: index == 0
                        ? [StudyActivityCategory.review.rawValue: 30 * 60_000]
                        : [:]
                )
            )
        }
        return makeRange(
            key: vector.key,
            startsAt: vector.startsAt,
            endsAt: vector.endsAt,
            buckets: buckets
        )
    }

    private func makeRange(_ vector: Fixture.AnalyticsCase) -> StudyTimeAnalyticsRange {
        makeRange(
            key: vector.key,
            startsAt: vector.startsAt,
            endsAt: vector.endsAt,
            buckets: vector.buckets.map(\.analyticsBucket)
        )
    }

    private func makeRange(
        key: StudyTimeRange,
        startsAt: Date,
        endsAt: Date,
        buckets: [StudyTimeAnalyticsBucket]
    ) -> StudyTimeAnalyticsRange {
        let categories = buckets.reduce(into: [String: Int]()) { totals, bucket in
            bucket.categories.forEach { totals[$0.key, default: 0] += $0.value }
        }
        return StudyTimeAnalyticsRange(
            key: key,
            startsAt: startsAt,
            endsAt: endsAt,
            totalMs: categories.values.reduce(0, +),
            categories: categories,
            buckets: buckets
        )
    }

    private func assertConservation(
        _ projection: StudyTimeAnalyticsProjection,
        caseID: String
    ) {
        let categoryTotal = projection.includedCategoryList.reduce(0) {
            $0 + projection.duration(for: $1)
        }
        let bucketTotal = projection.analytics.buckets.reduce(0) {
            $0 + projection.duration(for: $1)
        }
        XCTAssertEqual(projection.totalDurationMs, categoryTotal, caseID)
        XCTAssertEqual(projection.totalDurationMs, bucketTotal, caseID)
    }

    private func fixture() throws -> Fixture {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom(ISO8601Milliseconds.decode)
        return try decoder.decode(Fixture.self, from: fixtureData())
    }

    private func fixtureData() throws -> Data {
        try Data(contentsOf: fixtureURL(extension: "json"))
    }

    private func fixtureURL(extension fileExtension: String) throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "study-time-analytics-v1",
                withExtension: fileExtension
            )
        )
    }

    private func calendar(timeZone identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601Milliseconds.date(from: value))
    }
}

private enum FixtureError: Error {
    case unsupportedComponent(String)
}

private struct Fixture: Decodable {
    let schemaVersion: Int
    let timeZone: String
    let provenance: Provenance
    let fixedAxes: [FixedAxis]
    let crossMidnight: AnalyticsCase
    let projectionCases: [AnalyticsCase]

    struct Provenance: Decodable {
        let alignedRepository: String
        let alignedCommit: String
        let alignedPath: String
    }

    struct FixedAxis: Decodable {
        let id: String
        let key: StudyTimeRange
        let startsAt: Date
        let endsAt: Date
        let component: String
        let bucketCount: Int
    }

    // Cross-midnight filter vectors and projection vectors intentionally share
    // their range/bucket shape; fields used by only one shape default below.
    struct AnalyticsCase: Decodable {
        let id: String?
        let key: StudyTimeRange
        let startsAt: Date
        let endsAt: Date
        let generatedAt: Date
        let buckets: [Bucket]
        let filters: [Filter]
        let included: [StudyActivityCategory]
        let expectedTotalMs: Int
        let expectedDailyAverageMs: Int
        let expectedElapsedDays: Int
        let expectedBestBucketStart: Date?

        var caseID: String { id ?? "cross-midnight" }

        enum CodingKeys: String, CodingKey {
            case id, key, startsAt, endsAt, generatedAt, buckets, filters, included
            case expectedTotalMs, expectedDailyAverageMs, expectedElapsedDays
            case expectedBestBucketStart
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(String.self, forKey: .id)
            key = try values.decode(StudyTimeRange.self, forKey: .key)
            startsAt = try values.decode(Date.self, forKey: .startsAt)
            endsAt = try values.decode(Date.self, forKey: .endsAt)
            generatedAt = try values.decode(Date.self, forKey: .generatedAt)
            buckets = try values.decode([Bucket].self, forKey: .buckets)
            filters = try values.decodeIfPresent([Filter].self, forKey: .filters) ?? []
            included = try values.decodeIfPresent(
                [StudyActivityCategory].self,
                forKey: .included
            ) ?? []
            expectedTotalMs = try values.decodeIfPresent(Int.self, forKey: .expectedTotalMs) ?? 0
            expectedDailyAverageMs = try values.decodeIfPresent(
                Int.self,
                forKey: .expectedDailyAverageMs
            ) ?? 0
            expectedElapsedDays = try values.decodeIfPresent(
                Int.self,
                forKey: .expectedElapsedDays
            ) ?? 0
            expectedBestBucketStart = try values.decodeIfPresent(
                Date.self,
                forKey: .expectedBestBucketStart
            )
        }
    }

    struct Bucket: Decodable {
        let startsAt: Date
        let endsAt: Date
        let categories: [String: Int]

        var analyticsBucket: StudyTimeAnalyticsBucket {
            StudyTimeAnalyticsBucket(
                startsAt: startsAt,
                endsAt: endsAt,
                totalMs: categories.values.reduce(0, +),
                categories: categories
            )
        }
    }

    struct Filter: Decodable {
        let id: String
        let included: [StudyActivityCategory]
        let expectedTotalMs: Int
        let expectedBucketMs: [Int]
    }
}

import CryptoKit
import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class APICompatibilityGoldenFixtureTests: XCTestCase {
    private static let providerCommit = "d6aad389ad55afa0803e65c37eb38db3844a21b7"
    private static let manifestSHA256 = "9307d9101632d48543a97825f525c2df5e61c351e6161e1747f620865ee1ef5a"

    private static let expectedFixtures: [String: ExpectedFixture] = [
        "study-card-summary.v1": .init(
            file: "study-card-summary-v1",
            sha256: "8be018c25fc3bb661abb1a88b92e6f54e1d9026913a5882c6b524e1da111811a",
            producer: "App\\Http\\Resources\\Study\\StudyCardSummaryResource"
        ),
        "google-calendar-connection.v1": .init(
            file: "google-calendar-connection-v1",
            sha256: "1b4aae07eca4b171cca63fb3f212b66e30eb794a6cd8bfa68dd4ed8f888d6a6d",
            producer: "App\\Domain\\Calendar\\Actions\\ShowGoogleCalendarConnectionAction"
        ),
        "study-activity-analytics.v1": .init(
            file: "study-activity-analytics-v1",
            sha256: "139ebccb5a1a7d68ab8ed4be2d0f8c7a96bd9d9be35a5ccfdb59f53c61ce8418",
            producer: "App\\Domain\\Study\\Actions\\BuildStudyActivityAnalyticsAction"
        ),
        "daily-audio-practice.v1": .init(
            file: "daily-audio-practice-v1",
            sha256: "ad4e45a304e743f04b8f2e8d492917ea844ed3df599e0e7dfae1552e2fb6dcf1",
            producer: "App\\Http\\Resources\\Study\\DailyAudioPracticeResource"
        ),
        "personal-weekly-recap.v1": .init(
            file: "personal-weekly-recap-v1",
            sha256: "0c81e9495d703db1ded8e73d4cf46422f8ce21813fd5828635961758e7aa7d2b",
            producer: "App\\Domain\\Study\\Actions\\BuildPersonalWeeklyRecapAction"
        ),
    ]

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testManifestPayloadAndChecksumBytesMatchPinnedProvider() throws {
        let manifestData = try fixtureData(named: "manifest-v1", extension: "json")
        XCTAssertEqual(sha256(manifestData), Self.manifestSHA256)
        XCTAssertEqual(
            try checksumContents(named: "manifest-v1"),
            "\(Self.manifestSHA256)  manifest-v1.json\n"
        )

        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(
            manifest.authority.repository,
            "andyroo2000/learning-os",
            "Provider commit: \(Self.providerCommit)"
        )
        XCTAssertEqual(
            manifest.authority.manifest,
            "tests/Fixtures/Compatibility/manifest-v1.json"
        )
        XCTAssertFalse(manifest.authority.productionRuntimeLoadsFixtures)
        XCTAssertEqual(manifest.fixtures.count, Self.expectedFixtures.count)

        for fixture in manifest.fixtures {
            let expected = try XCTUnwrap(Self.expectedFixtures[fixture.id], fixture.id)
            XCTAssertEqual(fixture.path, "tests/Fixtures/Compatibility/\(expected.file).json")
            XCTAssertEqual(
                fixture.checksumPath,
                "tests/Fixtures/Compatibility/\(expected.file).sha256"
            )
            XCTAssertEqual(fixture.sha256, expected.sha256)
            XCTAssertEqual(fixture.producer, expected.producer)

            let payload = try fixtureData(named: expected.file, extension: "json")
            XCTAssertEqual(sha256(payload), expected.sha256, fixture.id)
            XCTAssertEqual(
                try checksumContents(named: expected.file),
                "\(expected.sha256)  \(expected.file).json\n",
                fixture.id
            )
        }

        XCTAssertNil(
            Bundle.main.url(forResource: "manifest-v1", withExtension: "json"),
            "Compatibility fixtures must remain in the test bundle."
        )
    }

    func testStudyCardCasesDecodeThroughAPIClient() async throws {
        let native: StudyCard = try await decode(
            fixture: "study-card-summary-v1",
            caseID: "native-defaults",
            path: "/api/study/cards/native"
        )
        XCTAssertEqual(native.id, "01J60000000000000000000001")
        XCTAssertEqual(native.state.queueState, "new")
        XCTAssertNil(native.state.scheduler)
        XCTAssertEqual(native.masteryLevel, "apprentice")

        let imported: StudyCard = try await decode(
            fixture: "study-card-summary-v1",
            caseID: "imported-progression",
            path: "/api/study/cards/imported"
        )
        XCTAssertEqual(imported.syncId, "01J60000000000000000000002")
        XCTAssertEqual(imported.state.queueState, "review")
        XCTAssertEqual(imported.state.scheduler?["reps"], .number(12))
        XCTAssertEqual(imported.answerAudioSource, "imported")
    }

    func testGoogleCalendarConnectionCasesDecodeThroughAPIClient() async throws {
        let disconnected: GoogleCalendarConnectionStatus = try await decode(
            fixture: "google-calendar-connection-v1",
            caseID: "disconnected",
            path: "/api/integrations/google-calendar"
        )
        XCTAssertFalse(disconnected.connected)
        XCTAssertNil(disconnected.settings)
        XCTAssertNil(disconnected.sync)

        let connected: GoogleCalendarConnectionStatus = try await decode(
            fixture: "google-calendar-connection-v1",
            caseID: "connected-with-next-lesson",
            path: "/api/integrations/google-calendar"
        )
        XCTAssertTrue(connected.connected)
        XCTAssertEqual(connected.settings?.calendarIds, ["primary"])
        XCTAssertEqual(connected.sync?.status, .failed)
        XCTAssertEqual(connected.sync?.errorCode, "provider_unavailable")
        XCTAssertEqual(connected.nextLesson?.title, "iTalki with Yuki")
    }

    func testStudyAnalyticsDecodesThroughAPIClient() async throws {
        let analytics: StudyTimeAnalytics = try await decode(
            fixture: "study-activity-analytics-v1",
            caseID: "cross-midnight-all-categories",
            path: "/api/study/activity/analytics"
        )

        XCTAssertEqual(analytics.anchorDate, "2026-07-28")
        XCTAssertEqual(analytics.timezone, "America/New_York")
        XCTAssertEqual(analytics.ranges.map(\.key), [.today, .week, .month, .year, .all])
        XCTAssertEqual(analytics.range(.today)?.buckets.count, 24)
        XCTAssertEqual(analytics.range(.today)?.totalMs, 4_801_001)
        XCTAssertEqual(analytics.range(.all)?.totalMs, 6_601_002)
    }

    func testDailyAudioDetailErrorAndTrackTimingDecodeThroughAPIClient() async throws {
        let ready: DailyAudioPractice = try await decode(
            fixture: "daily-audio-practice-v1",
            caseID: "ready-with-ready-and-skipped-tracks",
            path: "/api/daily-audio-practice/10000000-0000-4000-8000-000000000001"
        )
        XCTAssertEqual(ready.status, "ready")
        XCTAssertEqual(ready.tracks.count, 2)
        let drill = try XCTUnwrap(ready.tracks.first)
        XCTAssertEqual(drill.scriptUnitsJson?.first?.type, "L2")
        XCTAssertEqual(drill.scriptUnitsJson?.first?.text, "会社")
        XCTAssertEqual(drill.timingData, [
            DailyAudioTiming(unitIndex: 0, startTime: 0, endTime: 1_200),
        ])
        XCTAssertEqual(drill.formattedDuration, "2:00")
        XCTAssertNil(ready.tracks.last?.timingData)

        let failed: DailyAudioPractice = try await decode(
            fixture: "daily-audio-practice-v1",
            caseID: "error-without-tracks",
            path: "/api/daily-audio-practice/10000000-0000-4000-8000-000000000002"
        )
        XCTAssertEqual(failed.status, "error")
        XCTAssertEqual(failed.errorMessage, "Generation failed.")
        XCTAssertTrue(failed.tracks.isEmpty)
    }

    func testWeeklyRecapCasesDecodeThroughAPIClient() async throws {
        let empty: WeeklyStudyRecap = try await decode(
            fixture: "personal-weekly-recap-v1",
            caseID: "empty-completed-week",
            path: "/api/study/weekly-recap"
        )
        XCTAssertEqual(empty.week.totalMs, 0)
        XCTAssertNil(empty.week.recallRate)
        XCTAssertNil(empty.week.bestDay)

        let active: WeeklyStudyRecap = try await decode(
            fixture: "personal-weekly-recap-v1",
            caseID: "owned-study-review-and-introduction-metrics",
            path: "/api/study/weekly-recap"
        )
        XCTAssertEqual(active.week.totalMs, 5_400_000)
        XCTAssertEqual(active.week.categories.conversation, 1_800_000)
        XCTAssertEqual(active.week.recallRate, 0.5)
        XCTAssertEqual(active.previousWeek.recallRate, 1)
    }

    private func decode<Response: Decodable & Sendable>(
        fixture: String,
        caseID: String,
        path: String
    ) async throws -> Response {
        let payload = try payloadData(fixture: fixture, caseID: caseID)
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, path)
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                payload
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        return try await api.request(path)
    }

    private func payloadData(fixture: String, caseID: String) throws -> Data {
        let data = try fixtureData(named: fixture, extension: "json")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let fixtureCase = try XCTUnwrap(
            cases.first { $0["id"] as? String == caseID },
            "Missing \(fixture) case \(caseID)"
        )
        return try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(fixtureCase["payload"]),
            options: [.sortedKeys]
        )
    }

    private func checksumContents(named name: String) throws -> String {
        String(
            decoding: try fixtureData(named: name, extension: "sha256"),
            as: UTF8.self
        )
    }

    private func fixtureData(named name: String, extension fileExtension: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: fileExtension),
            "Missing bundled fixture \(name).\(fileExtension)"
        )
        return try Data(contentsOf: url)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ExpectedFixture {
    let file: String
    let sha256: String
    let producer: String
}

private struct Manifest: Decodable {
    struct Authority: Decodable {
        let repository: String
        let manifest: String
        let productionRuntimeLoadsFixtures: Bool
    }

    struct Fixture: Decodable {
        let id: String
        let path: String
        let checksumPath: String
        let sha256: String
        let producer: String
    }

    let schemaVersion: Int
    let authority: Authority
    let fixtures: [Fixture]
}

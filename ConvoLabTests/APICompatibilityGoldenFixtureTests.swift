import CryptoKit
import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class APICompatibilityGoldenFixtureTests: XCTestCase {
    private static let providerCommit = "b90e7ce2b3fc976de30eb00bbe3a69e86c5dd98b"
    private static let manifestSHA256 = "aa895232d4f813f8b3934e433d6f9090dcb7f50696dd6448fd7edfea332cd1e7"

    private static let expectedFixtures: [String: ExpectedFixture] = [
        "study-card-summary.v1": .init(
            file: "study-card-summary-v1",
            sha256: "4f851708014cb1fa89fe387c79b0d6b3a2387051aad440ce2176e059aa2985d9",
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
            sha256: "b0583b74f2afe089cdcd9ee0f172b0a2c735e483c6cc80fa96da112cd63be2c1",
            producer: "App\\Http\\Resources\\Study\\DailyAudioPracticeResource"
        ),
        "personal-weekly-recap.v1": .init(
            file: "personal-weekly-recap-v1",
            sha256: "0c81e9495d703db1ded8e73d4cf46422f8ce21813fd5828635961758e7aa7d2b",
            producer: "App\\Domain\\Study\\Actions\\BuildPersonalWeeklyRecapAction"
        ),
        "known-kanji.v2": .init(
            file: "known-kanji-v2",
            sha256: "bb546274c903e9eb2578402b871f30294002e48487085b35e1cf5965c47827ac",
            producer: "App\\Domain\\Japanese\\Actions\\ShowKnownKanjiAction"
        ),
        "wanikani-transfer-bridge-update.v1": .init(
            file: "wanikani-transfer-bridge-update-v1",
            sha256: "5c7d7e397a941a50737c846ced56cfca969486fd2a4ae2e12b49342d79b79c7d",
            producer: "App\\Http\\Controllers\\Api\\Study\\UpdateWaniKaniTransferBridgeController"
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
        XCTAssertEqual(native.serverPresentation?.version, 1)
        XCTAssertEqual(native.presentation.front.heading, "聞く")
        XCTAssertEqual(native.presentation.back.heading, "to listen")

        let imported: StudyCard = try await decode(
            fixture: "study-card-summary-v1",
            caseID: "imported-progression",
            path: "/api/study/cards/imported"
        )
        XCTAssertEqual(imported.syncId, "01J60000000000000000000002")
        XCTAssertEqual(imported.state.queueState, "review")
        XCTAssertEqual(imported.state.scheduler?["reps"], .number(12))
        XCTAssertEqual(imported.answerAudioSource, "imported")
        XCTAssertEqual(
            imported.presentation.back.audioURL,
            URL(string: "/media/company.mp3")
        )
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
        XCTAssertEqual(drill.scriptUnitsJson?[1].type, "narration_L1")
        XCTAssertEqual(drill.scriptUnitsJson?[2].type, "L2")
        XCTAssertEqual(drill.scriptUnitsJson?[2].text, "会社")
        XCTAssertEqual(drill.timingData, [
            DailyAudioTiming(unitIndex: 1, startTime: 0, endTime: 600),
            DailyAudioTiming(unitIndex: 2, startTime: 600, endTime: 1_200),
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

    func testCanonicalDailyAudioTimingsReferenceNonMarkerScriptUnits() async throws {
        let track: DailyAudioTrack = try await decode(
            payload: Data(#"""
            {
              "id":"track-1","practiceId":"practice-1","mode":"drill","status":"ready",
              "title":"Mixed script","sortOrder":0,
              "scriptUnitsJson":[
                {"type":"marker","text":null},
                {"type":"narration_L1","text":"company"},
                {"type":"L2","text":"会社"}
              ],
              "audioUrl":"/audio/mixed.mp3",
              "timingData":[
                {"unitIndex":1,"startTime":0,"endTime":1200},
                {"unitIndex":2,"startTime":1200,"endTime":2450}
              ],
              "approxDurationSeconds":2.45,"updatedAt":"2026-08-24T08:04:00.000Z"
            }
            """#.utf8),
            path: "/api/daily-audio-practice/fixture/track"
        )

        XCTAssertEqual(track.timingData, [
            DailyAudioTiming(unitIndex: 1, startTime: 0, endTime: 1_200),
            DailyAudioTiming(unitIndex: 2, startTime: 1_200, endTime: 2_450),
        ])
        XCTAssertEqual(
            DailyAudioTranscript.currentSpokenUnit(
                in: track,
                elapsedSeconds: 1.3,
                durationSeconds: nil
            )?.text,
            "会社"
        )
    }

    func testDailyAudioTrackRejectsLegacyTimingFields() async throws {
        let payload = Data(#"""
        {
          "id":"track-3","practiceId":"practice-1","mode":"drill","status":"ready",
          "title":"Legacy timing format","sortOrder":2,
          "scriptUnitsJson":[{"type":"L2","text":"会社"}],
          "audioUrl":"/audio/mixed.mp3",
          "timingData":[{"startMs":0,"endMs":2450}],
          "approxDurationSeconds":2.45,"updatedAt":"2026-08-24T08:04:00.000Z"
        }
        """#.utf8)

        do {
            let _: DailyAudioTrack = try await decode(
                payload: payload,
                path: "/api/daily-audio-practice/fixture/mixed-timing-formats"
            )
            XCTFail("Expected legacy timing fields to be rejected.")
        } catch APIClientError.decoding(path: let path, details: let details) {
            XCTAssertEqual(path, "/api/daily-audio-practice/fixture/mixed-timing-formats")
            XCTAssertTrue(details.contains("timingData"))
        }
    }

    func testDailyAudioTrackRejectsLegacyScriptUnitKind() async throws {
        let payload = Data(#"""
        {
          "id":"track-4","practiceId":"practice-1","mode":"drill","status":"ready",
          "title":"Legacy script format","sortOrder":3,
          "scriptUnitsJson":[{"kind":"target_language","text":"会社"}],
          "audioUrl":"/audio/legacy-script.mp3","timingData":null,
          "approxDurationSeconds":2.45,"updatedAt":"2026-08-24T08:04:00.000Z"
        }
        """#.utf8)

        do {
            let _: DailyAudioTrack = try await decode(
                payload: payload,
                path: "/api/daily-audio-practice/fixture/legacy-script-unit"
            )
            XCTFail("Expected a legacy script-unit kind to be rejected.")
        } catch APIClientError.decoding(path: let path, details: let details) {
            XCTAssertEqual(path, "/api/daily-audio-practice/fixture/legacy-script-unit")
            XCTAssertTrue(details.contains("scriptUnitsJson"))
        }
    }

    func testKnownKanjiV2AndLegacyCasesDecodeThroughAPIClient() async throws {
        let current: KnownKanjiSnapshot = try await decode(
            fixture: "known-kanji-v2",
            caseID: "connected-transfer-bridge",
            path: "/api/study/known-kanji"
        )
        XCTAssertEqual(current.version, 42)
        XCTAssertEqual(current.kanji, ["会", "橋", "社"])
        XCTAssertEqual(current.manualKanji, ["会", "社"])
        XCTAssertTrue(current.wanikani.connected)
        XCTAssertEqual(current.wanikani.reviewCount, 17)
        XCTAssertNotNil(current.wanikani.reviewCountUpdatedAt)
        let transferBridge = try XCTUnwrap(current.wanikani.transferBridge)
        XCTAssertTrue(transferBridge.enabled)
        XCTAssertEqual(transferBridge.importedVocabularyCount, 1)
        XCTAssertEqual(transferBridge.pendingVocabularyCount, 1)
        XCTAssertEqual(transferBridge.failedVocabularyCount, 1)
        XCTAssertNotNil(transferBridge.lastImportedAt)

        let legacy: KnownKanjiSnapshot = try await decode(
            fixture: "known-kanji-v2",
            caseID: "legacy-connected",
            path: "/api/study/known-kanji"
        )
        XCTAssertEqual(legacy.version, 42)
        XCTAssertTrue(legacy.wanikani.connected)
        XCTAssertNil(legacy.wanikani.reviewCount)
        XCTAssertNil(legacy.wanikani.reviewCountUpdatedAt)
        XCTAssertNil(legacy.wanikani.transferBridge)
    }

    func testWaniKaniTransferBridgeUpdateRequestAndResponseUseCanonicalContract() async throws {
        let expectedRequest = try caseData(
            fixture: "wanikani-transfer-bridge-update-v1",
            caseID: "enable",
            field: "request"
        )
        let response = try caseData(
            fixture: "wanikani-transfer-bridge-update-v1",
            caseID: "enable",
            field: "response"
        )
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(url.path, "/api/study/wanikani/transfer-bridge")
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Bool],
                try JSONSerialization.jsonObject(with: expectedRequest) as? [String: Bool]
            )
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                response
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )

        let updated: KnownKanjiSnapshot = try await api.request(
            "/api/study/wanikani/transfer-bridge",
            method: "PATCH",
            body: UpdateWaniKaniTransferBridgeRequest(enabled: true)
        )

        XCTAssertEqual(updated.version, 0)
        XCTAssertTrue(updated.wanikani.connected)
        let transferBridge = try XCTUnwrap(updated.wanikani.transferBridge)
        XCTAssertTrue(transferBridge.enabled)
        XCTAssertEqual(transferBridge.importedVocabularyCount, 0)
        XCTAssertEqual(transferBridge.pendingVocabularyCount, 0)
        XCTAssertEqual(transferBridge.failedVocabularyCount, 0)
        XCTAssertNil(transferBridge.lastImportedAt)
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
        return try await decode(payload: payload, path: path)
    }

    private func decode<Response: Decodable & Sendable>(
        payload: Data,
        path: String
    ) async throws -> Response {
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
        try caseData(fixture: fixture, caseID: caseID, field: "payload")
    }

    private func caseData(fixture: String, caseID: String, field: String) throws -> Data {
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
            withJSONObject: try XCTUnwrap(fixtureCase[field]),
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

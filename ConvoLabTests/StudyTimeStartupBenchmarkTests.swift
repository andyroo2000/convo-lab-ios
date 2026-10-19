import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeStartupBenchmarkTests: XCTestCase {
    /// Enable TIME_STARTUP_LARGE=1 for three independent cold/cached runs with
    /// 2,631 historical and 30 pending sessions. CI uses the same disk/API path
    /// with 120 + 3 records and shorter delays, without timing pass/fail limits.
    /// TIME_STARTUP_HISTORY_COUNT=20000 and TIME_STARTUP_ITERATIONS=1 opt into
    /// a separate stress workload; never combine it with the primary-size results.
    func testChartReadinessDuringStartupSynchronization() async throws {
        let large = ProcessInfo.processInfo.environment["TIME_STARTUP_LARGE"] == "1"
        let requestedIterations = Int(ProcessInfo.processInfo.environment["TIME_STARTUP_ITERATIONS"] ?? "") ?? 3
        let iterations = large ? min(3, max(1, requestedIterations)) : 1
        var results: [StudyTimeStartupMeasurement] = []
        for iteration in 1...iterations {
            for cached in [false, true] {
                let fixture = try StudyTimeStartupFixture(large: large, cached: cached)
                defer { fixture.cleanup() }
                results.append(try await measure(fixture, cached: cached, iteration: iteration))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(results)
        print("TIME_STARTUP_JSON \(String(decoding: data, as: UTF8.self))")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "time-startup.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func measure(
        _ fixture: StudyTimeStartupFixture, cached: Bool, iteration: Int
    ) async throws -> StudyTimeStartupMeasurement {
        let probe = StudyTimeStartupProbe()
        let activationStarted = ContinuousClock.now
        fixture.store.activate(userID: 42)
        let activationMS = StudyTimeStartupProbe.ms(activationStarted.duration(to: .now))
        XCTAssertEqual(fixture.store.analytics != nil, cached)
        probe.start {
            (fixture.store.analytics != nil, fixture.store.analytics?.generatedAt == fixture.now)
        }
        await fixture.store.synchronize()
        let timing = probe.finish(visible: fixture.store.analytics != nil,
                                  fresh: fixture.store.analytics?.generatedAt == fixture.now)
        let traffic = fixture.transport.snapshot()
        let records = try fixture.container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>())
        verify(fixture, records: records, traffic: traffic)
        XCTAssertNotNil(timing.firstFreshMS)
        return .init(scenario: cached ? "cached" : "cold", iteration: iteration,
                     historyCount: fixture.historyCount, pendingCount: fixture.pendingCount,
                     delaysMS: fixture.transport.delaysMS, activationMS: activationMS, timing: timing,
                     traffic: traffic, persistedSessions: records.count,
                     remainingPending: records.filter(\.syncPending).count)
    }

    private func verify(
        _ fixture: StudyTimeStartupFixture, records: [LocalStudyActivitySession], traffic: StudyTimeStartupTraffic
    ) {
        XCTAssertNil(fixture.store.syncErrorMessage)
        XCTAssertEqual(Set(records.map(\.clientSessionID)), Set(fixture.expected.map(\.clientSessionId)))
        let expected = Dictionary(uniqueKeysWithValues: fixture.expected.map { ($0.clientSessionId, $0) })
        for record in records { XCTAssertEqual(record.session, expected[record.clientSessionID]) }
        XCTAssertEqual(fixture.store.sessions.count, fixture.expected.count)
        XCTAssertFalse(records.contains(where: \.syncPending))
        XCTAssertEqual(traffic.uploadedSessions, fixture.pendingCount)
        XCTAssertEqual(traffic.requests.count, 3)
        XCTAssertEqual(traffic.inFlight, 0)
        XCTAssertFalse(traffic.requests.contains(where: \.cancelled))
        let upload = traffic.requests.first { $0.path.hasSuffix("/batch") }
        let analytics = traffic.requests.first { $0.path.hasSuffix("/activity-analytics") }
        XCTAssertGreaterThanOrEqual(analytics?.startedMS ?? -1, upload?.endedMS ?? .infinity)
        for range in fixture.store.analytics?.ranges ?? [] {
            XCTAssertEqual(range, fixture.analytics.range(range.key), "Uploaded work must be present in the fresh chart.")
        }
    }
}

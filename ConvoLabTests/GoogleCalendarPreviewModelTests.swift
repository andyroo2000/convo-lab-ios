import XCTest
@testable import ConvoLab

@MainActor
final class GoogleCalendarPreviewModelTests: XCTestCase {
    func testLoadedPreviewPreservesEligibilityImportStateAndReasons() async {
        let eligible = match(
            title: "iTalki 日本語", terms: ["iTalki", "日本語"], alreadySynced: false
        )
        let imported = match(title: "Japanese lesson", terms: ["lesson"], alreadySynced: true)
        let response = preview(matches: [eligible, imported], scanned: 9, matched: 2, truncated: true)
        let service = PreviewServiceFake(response: response)
        let request = GoogleCalendarPreviewRequest(
            calendarIds: ["work"], titleMatchTerms: ["iTalki", "日本語"]
        )
        let model = GoogleCalendarPreviewModel(service: service, request: request)

        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.response, response)
        XCTAssertEqual(service.requests, [request])
        XCTAssertEqual(eligible.statusLabel, "Eligible")
        XCTAssertEqual(imported.statusLabel, "Already imported")
        XCTAssertEqual(eligible.matchReason, "Matched: iTalki, 日本語")
        XCTAssertTrue(model.accessibilitySummary(for: imported).contains("Already imported"))
        XCTAssertEqual(model.durationText(5_400_000), "1h 30m")
        XCTAssertEqual(model.durationText(30_000), "<1m")
    }

    func testLoadingEmptyAndRetryStatesAreExplicit() async {
        let service = PreviewServiceFake(response: preview(matches: []))
        service.pause = true
        let model = GoogleCalendarPreviewModel(
            service: service,
            request: .init(calendarIds: ["work"], titleMatchTerms: ["lesson"])
        )
        let load = Task { await model.load() }
        while service.continuation == nil { await Task.yield() }

        XCTAssertEqual(model.state, .loading)
        service.resume()
        await load.value
        XCTAssertEqual(model.state, .empty)

        service.pause = false
        service.response = preview(matches: [match(title: "Lesson", terms: ["lesson"])])
        await model.load()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(service.requests.count, 2)
    }

    func testFailureIsSafeAndRetryable() async {
        let service = PreviewServiceFake(response: preview(matches: []))
        service.error = APIClientError.rejected(status: 500, message: "raw provider token secret")
        let model = GoogleCalendarPreviewModel(
            service: service,
            request: .init(calendarIds: ["work"], titleMatchTerms: ["lesson"])
        )

        await model.load()
        guard case let .failed(message) = model.state else { return XCTFail("Expected failure") }
        XCTAssertFalse(message.contains("secret"))
        XCTAssertNil(model.response)

        service.error = nil
        await model.load()
        XCTAssertEqual(model.state, .empty)
    }

    private static let start = Date(timeIntervalSince1970: 1_723_640_400)

    private func match(
        title: String,
        terms: [String],
        alreadySynced: Bool = false
    ) -> GoogleCalendarPreviewMatch {
        .init(
            calendarId: "work", calendarName: "Work", title: title,
            startsAt: Self.start, endsAt: Self.start.addingTimeInterval(3_600),
            durationMs: 3_600_000, matchedTerms: terms, alreadySynced: alreadySynced
        )
    }

    private func preview(
        matches: [GoogleCalendarPreviewMatch],
        scanned: Int = 0,
        matched: Int? = nil,
        truncated: Bool = false
    ) -> GoogleCalendarPreviewResponse {
        .init(
            generatedAt: Self.start, startsAt: Self.start.addingTimeInterval(-31 * 86_400),
            endsAt: Self.start, scannedEventCount: scanned,
            matchedEventCount: matched ?? matches.count, truncated: truncated, matches: matches
        )
    }
}

@MainActor
private final class PreviewServiceFake: GoogleCalendarConnectionServing {
    var response: GoogleCalendarPreviewResponse
    var error: Error?
    var pause = false
    var continuation: CheckedContinuation<GoogleCalendarPreviewResponse, Never>?
    private(set) var requests: [GoogleCalendarPreviewRequest] = []

    init(response: GoogleCalendarPreviewResponse) { self.response = response }

    func status() async throws -> GoogleCalendarConnectionStatus {
        .init(
            connected: true, accountEmail: "andrew@example.com", scopes: ["calendar.readonly"],
            settings: nil, connectedAt: nil, lastSyncedAt: nil
        )
    }
    func authorizationURL() async throws -> URL { URL(string: "https://example.test")! }
    func calendars() async throws -> GoogleCalendarListResponse { .init(calendars: [], truncated: false) }
    func preview(_ request: GoogleCalendarPreviewRequest) async throws -> GoogleCalendarPreviewResponse {
        requests.append(request)
        if let error { throw error }
        guard pause else { return response }
        return await withCheckedContinuation { continuation = $0 }
    }
    func updateSettings(_ settings: GoogleCalendarSettings) async throws -> GoogleCalendarSettings { settings }
    func disconnect() async throws {}

    func resume() {
        continuation?.resume(returning: response)
        continuation = nil
    }
}

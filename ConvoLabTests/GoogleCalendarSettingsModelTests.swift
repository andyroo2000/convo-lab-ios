import XCTest
@testable import ConvoLab

@MainActor
final class GoogleCalendarSettingsModelTests: XCTestCase {
    func testLoadPreservesSelectionsAndSaveUsesExactExistingRules() async {
        let existing = GoogleCalendarSettings(
            calendarIds: ["primary", "unavailable"],
            titleMatchTerms: [" iTalki ", "学校"],
            syncEnabled: false
        )
        let service = CalendarSettingsServiceFake(
            settings: existing,
            calendars: [
                .init(id: "primary", name: "Personal", primary: true),
                .init(id: "lessons", name: "Lessons", primary: false),
            ]
        )
        var refreshCount = 0
        let model = GoogleCalendarSettingsModel(service: service, initialSettings: existing) {
            refreshCount += 1
        }

        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.selectedCalendarIDs, ["primary", "unavailable"])
        XCTAssertEqual(model.unavailableSelectedCount, 1)
        model.toggleCalendar(id: "primary")
        model.toggleCalendar(id: "lessons")
        let didSave = await model.save()
        XCTAssertTrue(didSave)
        XCTAssertEqual(
            service.updateRequests,
            [.init(
                calendarIds: ["unavailable", "lessons"],
                titleMatchTerms: [" iTalki ", "学校"],
                syncEnabled: false
            )]
        )
        XCTAssertEqual(refreshCount, 1)
    }

    func testAtLeastOneCalendarIsRequiredAndCancelDoesNotMutate() async {
        let settings = GoogleCalendarSettings(
            calendarIds: ["primary"], titleMatchTerms: ["lesson"], syncEnabled: true
        )
        let service = CalendarSettingsServiceFake(
            settings: settings,
            calendars: [.init(id: "primary", name: "Personal", primary: true)]
        )
        let model = GoogleCalendarSettingsModel(service: service, initialSettings: settings)
        await model.load()

        model.toggleCalendar(id: "primary")

        XCTAssertFalse(model.canSave)
        let didSave = await model.save()
        XCTAssertFalse(didSave)
        XCTAssertEqual(model.saveErrorMessage, "Select at least one calendar to save.")
        XCTAssertTrue(service.updateRequests.isEmpty)
        XCTAssertEqual(service.statusResponse.settings, settings)

        model.toggleCalendar(id: "primary")
        XCTAssertTrue(model.canSave)
        // Dismissing the sheet performs no model action and therefore no request.
        XCTAssertTrue(service.updateRequests.isEmpty)
        XCTAssertEqual(service.statusResponse.settings, settings)
    }

    func testLoadingAndEmptyStatesAreExplicit() async {
        let service = CalendarSettingsServiceFake(
            settings: .init(calendarIds: ["primary"], titleMatchTerms: ["lesson"], syncEnabled: true),
            calendars: []
        )
        service.pauseCalendars = true
        let model = GoogleCalendarSettingsModel(service: service, initialSettings: nil)
        let load = Task { await model.load() }
        while service.calendarContinuation == nil { await Task.yield() }

        XCTAssertEqual(model.state, .loading)
        service.resumeCalendars()
        await load.value

        XCTAssertEqual(model.state, .empty)
        XCTAssertFalse(model.canSave)

        service.pauseCalendars = false
        service.calendarResponse = .init(
            calendars: [.init(id: "primary", name: "Personal", primary: true)],
            truncated: false
        )
        await model.load()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertTrue(model.canSave)
    }

    func testErrorAndUnconfiguredStatesDoNotLeakOrInventSettings() async {
        let failing = CalendarSettingsServiceFake(
            settings: .init(calendarIds: ["primary"], titleMatchTerms: ["lesson"], syncEnabled: true),
            calendars: []
        )
        failing.calendarError = APIClientError.rejected(status: 500, message: "raw provider secret")
        let failedModel = GoogleCalendarSettingsModel(service: failing, initialSettings: nil)
        await failedModel.load()
        guard case let .failed(message) = failedModel.state else {
            return XCTFail("Expected a controlled failure state")
        }
        XCTAssertFalse(message.contains("secret"))

        let unconfigured = CalendarSettingsServiceFake(
            settings: nil,
            calendars: [.init(id: "primary", name: "Personal", primary: true)]
        )
        let unconfiguredModel = GoogleCalendarSettingsModel(service: unconfigured, initialSettings: nil)
        await unconfiguredModel.load()

        XCTAssertEqual(unconfiguredModel.state, .unconfigured)
        XCTAssertTrue(unconfiguredModel.selectedCalendarIDs.isEmpty)
        let didSave = await unconfiguredModel.save()
        XCTAssertFalse(didSave)
        XCTAssertTrue(unconfigured.updateRequests.isEmpty)
    }
}

@MainActor
private final class CalendarSettingsServiceFake: GoogleCalendarConnectionServing {
    var statusResponse: GoogleCalendarConnectionStatus
    var calendarResponse: GoogleCalendarListResponse
    var calendarError: Error?
    var pauseCalendars = false
    var calendarContinuation: CheckedContinuation<GoogleCalendarListResponse, Never>?
    private(set) var updateRequests: [GoogleCalendarSettings] = []

    init(settings: GoogleCalendarSettings?, calendars: [GoogleCalendar]) {
        statusResponse = .init(
            connected: true,
            accountEmail: "andrew@example.com",
            scopes: ["calendar.readonly"],
            settings: settings,
            connectedAt: nil,
            lastSyncedAt: nil
        )
        calendarResponse = .init(calendars: calendars, truncated: false)
    }

    func status() async throws -> GoogleCalendarConnectionStatus { statusResponse }
    func authorizationURL() async throws -> URL { URL(string: "https://example.test")! }
    func calendars() async throws -> GoogleCalendarListResponse {
        if let calendarError { throw calendarError }
        guard pauseCalendars else { return calendarResponse }
        return await withCheckedContinuation { calendarContinuation = $0 }
    }
    func updateSettings(_ settings: GoogleCalendarSettings) async throws -> GoogleCalendarSettings {
        updateRequests.append(settings)
        return settings
    }
    func disconnect() async throws {}

    func resumeCalendars() {
        calendarContinuation?.resume(returning: calendarResponse)
        calendarContinuation = nil
    }
}

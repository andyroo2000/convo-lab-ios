import XCTest
@testable import ConvoLab

@MainActor
final class GoogleCalendarSettingsModelTests: XCTestCase {
    func testLoadPreservesSelectionsAndSaveUsesFreshExistingRules() async {
        let existing = GoogleCalendarSettings(
            calendarIds: ["primary", "unavailable", "remote-removed"],
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
        XCTAssertEqual(model.selectedCalendarIDs, ["primary", "unavailable", "remote-removed"])
        XCTAssertEqual(model.titleMatchTerms, [" iTalki ", "学校"])
        XCTAssertEqual(model.unavailableSelectedCount, 2)
        XCTAssertEqual(model.unavailableSelectedCalendarIDs, ["unavailable", "remote-removed"])
        model.toggleCalendar(id: "primary")
        model.toggleCalendar(id: "lessons")
        model.removeTitleMatchTerm(at: 0)
        XCTAssertTrue(model.addTitleMatchTerm(" lesson "))
        service.statusResponse = CalendarSettingsServiceFake.status(
            settings: .init(
                calendarIds: ["unavailable", "remote"],
                titleMatchTerms: ["remote edit"],
                syncEnabled: true
            )
        )
        let didSave = await model.save()
        XCTAssertTrue(didSave)
        XCTAssertEqual(
            service.updateRequests,
            [.init(
                calendarIds: ["unavailable", "remote", "lessons"],
                titleMatchTerms: ["remote edit", "lesson"],
                syncEnabled: true
            )]
        )
        XCTAssertEqual(refreshCount, 1)
    }

    func testInitialSetupSavesExactPayloadWithoutInventingDefaults() async {
        let service = CalendarSettingsServiceFake(
            settings: nil,
            calendars: [.init(id: "primary", name: "Personal", primary: true)]
        )
        let model = GoogleCalendarSettingsModel(service: service, initialSettings: nil)
        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertTrue(model.selectedCalendarIDs.isEmpty)
        XCTAssertTrue(model.titleMatchTerms.isEmpty)
        XCTAssertFalse(model.canSave)

        model.toggleCalendar(id: "primary")
        XCTAssertTrue(model.addTitleMatchTerm("  iTalki  "))
        XCTAssertTrue(model.canSave)
        let didSave = await model.save()
        XCTAssertTrue(didSave)
        XCTAssertEqual(service.updateRequests, [
            .init(calendarIds: ["primary"], titleMatchTerms: ["iTalki"], syncEnabled: false),
        ])
    }

    func testRemoteSetupAppearingWhileOpenReceivesLocalDelta() async {
        let service = CalendarSettingsServiceFake(
            settings: nil,
            calendars: [
                .init(id: "primary", name: "Personal", primary: true),
                .init(id: "lessons", name: "Lessons", primary: false),
            ]
        )
        let model = GoogleCalendarSettingsModel(service: service, initialSettings: nil)
        await model.load()
        model.toggleCalendar(id: "lessons")
        XCTAssertTrue(model.addTitleMatchTerm("学校"))
        service.statusResponse = CalendarSettingsServiceFake.status(settings: .init(
            calendarIds: ["primary"], titleMatchTerms: ["remote"], syncEnabled: true
        ))

        let didSave = await model.save()
        XCTAssertTrue(didSave)
        XCTAssertEqual(service.updateRequests, [
            .init(
                calendarIds: ["primary", "lessons"],
                titleMatchTerms: ["remote", "学校"],
                syncEnabled: true
            ),
        ])
    }

    func testPreviewUsesCurrentCanonicalSelectionsWithoutSaving() async {
        let settings = GoogleCalendarSettings(
            calendarIds: ["primary", "stale"], titleMatchTerms: [" iTalki "], syncEnabled: true
        )
        let service = CalendarSettingsServiceFake(
            settings: settings,
            calendars: [
                .init(id: "primary", name: "Personal", primary: true),
                .init(id: "lessons", name: "Lessons", primary: false),
            ]
        )
        let model = GoogleCalendarSettingsModel(service: service, initialSettings: settings)
        await model.load()
        model.removeUnavailableCalendar(id: "stale")
        model.toggleCalendar(id: "lessons")
        XCTAssertTrue(model.addTitleMatchTerm("学校"))

        let preview = model.makePreviewModel()

        XCTAssertEqual(
            preview?.request,
            .init(calendarIds: ["primary", "lessons"], titleMatchTerms: ["iTalki", "学校"])
        )
        XCTAssertTrue(service.updateRequests.isEmpty)
    }

    func testTermEditingTrimsDeduplicatesValidatesAndPreservesOrder() async {
        let service = CalendarSettingsServiceFake(
            settings: .init(calendarIds: ["primary"], titleMatchTerms: ["existing"], syncEnabled: true),
            calendars: [.init(id: "primary", name: "Personal", primary: true)]
        )
        let model = GoogleCalendarSettingsModel(service: service, initialSettings: service.statusResponse.settings)
        await model.load()

        XCTAssertFalse(model.addTitleMatchTerm("  "))
        XCTAssertEqual(model.saveErrorMessage, GoogleCalendarSettingsValidationError.emptyTerm.localizedDescription)
        XCTAssertFalse(model.addTitleMatchTerm(String(repeating: "界", count: 101)))
        XCTAssertEqual(model.saveErrorMessage, GoogleCalendarSettingsValidationError.termTooLong.localizedDescription)
        XCTAssertTrue(model.addTitleMatchTerm(" Übung "))
        XCTAssertFalse(model.addTitleMatchTerm("üBUNG"))
        XCTAssertEqual(model.saveErrorMessage, "That title-match term is already included.")
        XCTAssertTrue(model.addTitleMatchTerm("Straße"))
        XCTAssertTrue(model.addTitleMatchTerm("STRASSE"))
        XCTAssertTrue(model.addTitleMatchTerm("学校"))
        XCTAssertEqual(model.titleMatchTerms, ["existing", "Übung", "Straße", "STRASSE", "学校"])

        model.removeTitleMatchTerm(at: 1)
        XCTAssertEqual(model.titleMatchTerms, ["existing", "Straße", "STRASSE", "学校"])
        for index in 4...49 {
            XCTAssertTrue(model.addTitleMatchTerm("term-\(index)"))
        }
        XCTAssertEqual(model.titleMatchTerms.count, 50)
        XCTAssertFalse(model.addTitleMatchTerm("one-too-many"))
        XCTAssertEqual(model.saveErrorMessage, GoogleCalendarSettingsValidationError.termCount.localizedDescription)
    }

    func testInvalidLoadedTermHasVisibleValidationAndCanBeRepaired() async {
        let invalidTerm = String(repeating: "e\u{301}", count: 50) + "a"
        let settings = GoogleCalendarSettings(
            calendarIds: ["primary"], titleMatchTerms: [invalidTerm], syncEnabled: true
        )
        let service = CalendarSettingsServiceFake(
            settings: settings,
            calendars: [.init(id: "primary", name: "Personal", primary: true)]
        )
        let model = GoogleCalendarSettingsModel(service: service, initialSettings: settings)
        await model.load()

        XCTAssertEqual(model.titleMatchTerms, [invalidTerm])
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(
            model.titleTermsValidationMessage,
            GoogleCalendarSettingsValidationError.termTooLong.localizedDescription
        )
        model.removeTitleMatchTerm(at: 0)
        XCTAssertTrue(model.addTitleMatchTerm("lesson"))
        XCTAssertNil(model.titleTermsValidationMessage)
        XCTAssertTrue(model.canSave)
    }

    func testUnavailableSelectionCanBeRemovedAndSelectionStopsAt25() async {
        let settings = GoogleCalendarSettings(
            calendarIds: ["stale"], titleMatchTerms: ["lesson"], syncEnabled: true
        )
        let calendars = (1...26).map {
            GoogleCalendar(id: "calendar-\($0)", name: "Calendar \($0)", primary: false)
        }
        let service = CalendarSettingsServiceFake(settings: settings, calendars: calendars)
        let model = GoogleCalendarSettingsModel(service: service, initialSettings: settings)
        await model.load()

        model.removeUnavailableCalendar(id: "stale")
        XCTAssertFalse(model.selectedCalendarIDs.contains("stale"))
        for calendar in calendars.prefix(25) { model.toggleCalendar(id: calendar.id) }
        XCTAssertEqual(model.selectedCalendarIDs.count, 25)
        model.toggleCalendar(id: calendars[25].id)
        XCTAssertEqual(model.selectedCalendarIDs.count, 25)
        XCTAssertFalse(model.selectedCalendarIDs.contains("calendar-26"))
        XCTAssertEqual(
            model.saveErrorMessage,
            GoogleCalendarSettingsValidationError.calendarCount.localizedDescription
        )
        let didSave = await model.save()
        XCTAssertTrue(didSave)
        XCTAssertFalse(service.updateRequests[0].calendarIds.contains("stale"))
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
        model.removeTitleMatchTerm(at: 0)

        XCTAssertFalse(model.canSave)
        let didSave = await model.save()
        XCTAssertFalse(didSave)
        XCTAssertEqual(model.saveErrorMessage, "Select at least one calendar to save.")
        XCTAssertTrue(service.updateRequests.isEmpty)
        XCTAssertEqual(service.statusResponse.settings, settings)

        model.toggleCalendar(id: "primary")
        XCTAssertFalse(model.canSave)
        let missingTermSave = await model.save()
        XCTAssertFalse(missingTermSave)
        XCTAssertEqual(model.saveErrorMessage, "Add at least one title-match term to save.")
        XCTAssertTrue(model.addTitleMatchTerm("lesson"))
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

    func testErrorsDoNotLeakRawServerDetails() async {
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

        let saveFailure = CalendarSettingsServiceFake(
            settings: .init(calendarIds: ["primary"], titleMatchTerms: ["lesson"], syncEnabled: true),
            calendars: [.init(id: "primary", name: "Personal", primary: true)]
        )
        saveFailure.updateError = APIClientError.rejected(status: 500, message: "raw save secret")
        let saveModel = GoogleCalendarSettingsModel(
            service: saveFailure, initialSettings: saveFailure.statusResponse.settings
        )
        await saveModel.load()
        let didSave = await saveModel.save()
        XCTAssertFalse(didSave)
        XCTAssertFalse(saveModel.saveErrorMessage?.contains("secret") ?? true)
    }
}

@MainActor
private final class CalendarSettingsServiceFake: GoogleCalendarConnectionServing {
    var statusResponse: GoogleCalendarConnectionStatus
    var calendarResponse: GoogleCalendarListResponse
    var calendarError: Error?
    var updateError: Error?
    var pauseCalendars = false
    var calendarContinuation: CheckedContinuation<GoogleCalendarListResponse, Never>?
    private(set) var updateRequests: [GoogleCalendarSettings] = []

    init(settings: GoogleCalendarSettings?, calendars: [GoogleCalendar]) {
        statusResponse = Self.status(settings: settings)
        calendarResponse = .init(calendars: calendars, truncated: false)
    }

    static func status(settings: GoogleCalendarSettings?) -> GoogleCalendarConnectionStatus {
        .init(
            connected: true,
            accountEmail: "andrew@example.com",
            scopes: ["calendar.readonly"],
            settings: settings,
            connectedAt: nil,
            lastSyncedAt: nil
        )
    }

    func status() async throws -> GoogleCalendarConnectionStatus { statusResponse }
    func authorizationURL() async throws -> URL { URL(string: "https://example.test")! }
    func calendars() async throws -> GoogleCalendarListResponse {
        if let calendarError { throw calendarError }
        guard pauseCalendars else { return calendarResponse }
        return await withCheckedContinuation { calendarContinuation = $0 }
    }
    func updateSettings(_ settings: GoogleCalendarSettings) async throws -> GoogleCalendarSettings {
        if let updateError { throw updateError }
        updateRequests.append(settings)
        return settings
    }
    func preview(_ request: GoogleCalendarPreviewRequest) async throws -> GoogleCalendarPreviewResponse {
        .init(
            generatedAt: .now, startsAt: .now, endsAt: .now,
            scannedEventCount: 0, matchedEventCount: 0, truncated: false, matches: []
        )
    }
    func disconnect() async throws {}

    func resumeCalendars() {
        calendarContinuation?.resume(returning: calendarResponse)
        calendarContinuation = nil
    }
}

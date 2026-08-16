import AuthenticationServices
import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class GoogleCalendarConnectionTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testCallbackAcceptsOnlyTheFixedStudyTimeContract() throws {
        let connected = URL(string: "convolab://study-time?calendarConnection=connected")!
        XCTAssertEqual(try GoogleCalendarCallback.parse(connected), .init(connected: true, reason: nil))
        let denied = URL(string: "convolab://study-time?calendarConnection=error&reason=access_denied")!
        XCTAssertEqual(try GoogleCalendarCallback.parse(denied), .init(connected: false, reason: "access_denied"))
        let wrongHost = URL(string: "convolab://settings?calendarConnection=connected")!
        XCTAssertThrowsError(try GoogleCalendarCallback.parse(wrongHost))
        let wrongScheme = URL(string: "https://study-time?calendarConnection=connected")!
        XCTAssertThrowsError(try GoogleCalendarCallback.parse(wrongScheme))
    }

    func testLiveServiceUsesTheDocumentedRoutesAndIOSCompletionTarget() async throws {
        let api = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: request.httpMethod == "DELETE" ? 204 : 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/study/google-calendar"):
                return (
                    response,
                    Data(
                        #"{"connected":true,"accountEmail":"andrew@example.com","scopes":["calendar.readonly"],"settings":{"calendarIds":["primary"],"titleMatchTerms":["iTalki"],"syncEnabled":true},"connectedAt":"2026-08-15T14:00:00Z","lastSyncedAt":"2026-08-15T14:11:12Z"}"#.utf8
                    )
                )
            case ("POST", "/api/study/google-calendar/connect"):
                let body = try requestBody(request)
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                )
                XCTAssertEqual(json, ["completionTarget": "ios"])
                return (
                    response,
                    Data(#"{"authorizationUrl":"https://accounts.google.com/oauth"}"#.utf8)
                )
            case ("DELETE", "/api/study/google-calendar"):
                return (response, Data())
            case ("GET", "/api/study/google-calendar/calendars"):
                return (
                    response,
                    Data(#"{"calendars":[{"id":"primary","name":"Andrew","primary":true}],"truncated":false}"#.utf8)
                )
            case ("PUT", "/api/study/google-calendar/settings"):
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any]
                )
                XCTAssertEqual(Set(json.keys), ["calendarIds", "titleMatchTerms", "syncEnabled"])
                XCTAssertEqual(json["calendarIds"] as? [String], ["primary"])
                XCTAssertEqual(json["titleMatchTerms"] as? [String], ["iTalki"])
                XCTAssertEqual(json["syncEnabled"] as? Bool, true)
                return (
                    response,
                    Data(#"{"calendarIds":["primary"],"titleMatchTerms":["iTalki"],"syncEnabled":true}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                throw URLError(.badURL)
            }
        }
        let service = LiveGoogleCalendarConnectionService(api: api)
        let status = try await service.status()
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.accountEmail, "andrew@example.com")
        XCTAssertEqual(status.scopes, ["calendar.readonly"])
        XCTAssertEqual(
            status.settings,
            .init(calendarIds: ["primary"], titleMatchTerms: ["iTalki"], syncEnabled: true)
        )
        XCTAssertEqual(
            status.lastSyncedAt,
            ISO8601DateFormatter().date(from: "2026-08-15T14:11:12Z")
        )
        let authorizationURL = try await service.authorizationURL()
        XCTAssertEqual(authorizationURL.absoluteString, "https://accounts.google.com/oauth")
        let calendars = try await service.calendars()
        XCTAssertEqual(calendars, .init(
            calendars: [.init(id: "primary", name: "Andrew", primary: true)],
            truncated: false
        ))
        let settings = try await service.updateSettings(
            .init(calendarIds: ["primary"], titleMatchTerms: ["iTalki"], syncEnabled: true)
        )
        XCTAssertEqual(settings, status.settings)
        try await service.disconnect()
    }

    func testDisconnectedStatusDecodesExplicitNullSettings() async throws {
        let api = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"connected":false,"accountEmail":null,"scopes":[],"settings":null,"connectedAt":null,"lastSyncedAt":null}"#.utf8))
        }

        let status = try await LiveGoogleCalendarConnectionService(api: api).status()

        XCTAssertFalse(status.connected)
        XCTAssertEqual(status.scopes, [])
        XCTAssertNil(status.settings)
    }

    func testNewEndpointsMapControlledCalendarErrors() async throws {
        for (status, expected) in [
            (401, GoogleCalendarConnectionError.sessionExpired),
            (409, GoogleCalendarConnectionError.notConnected),
            (422, .invalidSettings),
            (429, .rateLimited),
            (502, .providerUnavailable),
            (503, .providerUnavailable),
            (500, .requestFailed),
        ] {
            let api = makeClient { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"message":"raw provider token secret"}"#.utf8))
            }
            do {
                _ = try await LiveGoogleCalendarConnectionService(api: api).calendars()
                XCTFail("Expected status \(status) to fail")
            } catch {
                XCTAssertEqual(error as? GoogleCalendarConnectionError, expected)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
                if expected == .requestFailed {
                    XCTAssertEqual(
                        error.localizedDescription,
                        "Something went wrong with Google Calendar. Please try again."
                    )
                }
            }
        }
    }

    func testSettingsDraftCanonicalizesOpaqueIDsAndUnicodeTerms() throws {
        let settings = try GoogleCalendarSettingsDraft(
            calendarIds: [" primary ", "primary", "PRIMARY"],
            titleMatchTerms: [
                " iTalki ", "ITALKI", "学校", "学校", "Übung", "üBUNG", "Straße", "STRASSE",
            ],
            syncEnabled: false
        ).canonicalized()

        XCTAssertEqual(settings.calendarIds, ["primary", "PRIMARY"])
        XCTAssertEqual(settings.titleMatchTerms, ["iTalki", "学校", "Übung", "Straße", "STRASSE"])
        XCTAssertFalse(settings.syncEnabled)
    }

    func testSettingsDraftValidatesCountsAndUnicodeScalarLengths() throws {
        XCTAssertThrowsError(try GoogleCalendarSettingsDraft(
            calendarIds: [], titleMatchTerms: ["lesson"], syncEnabled: true
        ).canonicalized()) { XCTAssertEqual($0 as? GoogleCalendarSettingsValidationError, .calendarCount) }
        XCTAssertThrowsError(try GoogleCalendarSettingsDraft(
            calendarIds: Array(repeating: "primary", count: 26),
            titleMatchTerms: ["lesson"],
            syncEnabled: true
        ).canonicalized()) { XCTAssertEqual($0 as? GoogleCalendarSettingsValidationError, .calendarCount) }
        XCTAssertThrowsError(try GoogleCalendarSettingsDraft(
            calendarIds: [String(repeating: "界", count: 1_025)],
            titleMatchTerms: ["lesson"],
            syncEnabled: true
        ).canonicalized()) { XCTAssertEqual($0 as? GoogleCalendarSettingsValidationError, .calendarIDTooLong) }
        XCTAssertNoThrow(try GoogleCalendarSettingsDraft(
            calendarIds: ["primary"],
            titleMatchTerms: [String(repeating: "e\u{301}", count: 50)],
            syncEnabled: true
        ).canonicalized())
        XCTAssertThrowsError(try GoogleCalendarSettingsDraft(
            calendarIds: ["primary"], titleMatchTerms: [], syncEnabled: true
        ).canonicalized()) { XCTAssertEqual($0 as? GoogleCalendarSettingsValidationError, .termCount) }
        XCTAssertThrowsError(try GoogleCalendarSettingsDraft(
            calendarIds: ["primary"],
            titleMatchTerms: Array(repeating: "lesson", count: 51),
            syncEnabled: true
        ).canonicalized()) { XCTAssertEqual($0 as? GoogleCalendarSettingsValidationError, .termCount) }
        XCTAssertThrowsError(try GoogleCalendarSettingsDraft(
            calendarIds: ["primary"],
            titleMatchTerms: [String(repeating: "e\u{301}", count: 50) + "a"],
            syncEnabled: true
        ).canonicalized()) { XCTAssertEqual($0 as? GoogleCalendarSettingsValidationError, .termTooLong) }
    }

    func testAuthorizationURLRequiresHTTPS() async {
        let api = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"authorizationUrl":"http://example.test/oauth"}"#.utf8))
        }
        do {
            _ = try await LiveGoogleCalendarConnectionService(api: api).authorizationURL()
            XCTFail("Expected insecure authorization URL to be rejected")
        } catch {
            XCTAssertEqual(error as? GoogleCalendarConnectionError, .invalidAuthorizationURL)
        }
    }

    func testConnectRefreshesStatusAndDisconnectClearsIt() async throws {
        let service = TestGoogleCalendarConnectionService()
        service.statusResponse = GoogleCalendarConnectionStatus(
            connected: true,
            accountEmail: "andrew@example.com",
            scopes: ["calendar.readonly"],
            settings: .init(calendarIds: ["primary"], titleMatchTerms: ["iTalki"], syncEnabled: true),
            connectedAt: Date(timeIntervalSince1970: 100),
            lastSyncedAt: Date(timeIntervalSince1970: 200)
        )
        let callback = URL(string: "convolab://study-time?calendarConnection=connected")!
        let authorizer = TestGoogleCalendarAuthorizer(result: .success(callback))
        let store = try makeStore(service: service, authorizer: authorizer)
        store.activate(userID: 42)
        service.pauseStatus = true
        let load = Task { await store.loadGoogleCalendarConnection() }
        while service.statusContinuation == nil { await Task.yield() }
        await store.connectGoogleCalendar()
        XCTAssertTrue(authorizer.openedURLs.isEmpty)
        service.resumeStatus()
        await load.value
        service.pauseStatus = false
        await store.connectGoogleCalendar()
        XCTAssertEqual(authorizer.openedURLs, [service.authorizationURLValue])
        XCTAssertEqual(store.googleCalendarStatus, service.statusResponse)
        XCTAssertNotNil(store.makeGoogleCalendarSettingsModel())
        XCTAssertNil(store.googleCalendarErrorMessage)
        XCTAssertFalse(store.googleCalendarIsWorking)
        await store.disconnectGoogleCalendar()
        XCTAssertEqual(service.disconnectCount, 1)
        XCTAssertEqual(store.googleCalendarStatus?.connected, false)
        XCTAssertNil(store.makeGoogleCalendarSettingsModel())
    }

    func testConnectionFailureShowsControlledMessageAndCanRetryStatus() async throws {
        let service = TestGoogleCalendarConnectionService()
        let denied = URL(string: "convolab://study-time?calendarConnection=error&reason=access_denied")!
        let authorizer = TestGoogleCalendarAuthorizer(result: .success(denied))
        let store = try makeStore(service: service, authorizer: authorizer)
        store.activate(userID: 42)
        await store.connectGoogleCalendar()
        XCTAssertEqual(store.googleCalendarErrorMessage, "Google Calendar access wasn’t granted.")
        service.statusResponse = .init(
            connected: false, accountEmail: nil, scopes: [], settings: nil,
            connectedAt: nil, lastSyncedAt: nil
        )
        await store.loadGoogleCalendarConnection()
        XCTAssertEqual(store.googleCalendarStatus?.connected, false)
        XCTAssertNil(store.googleCalendarErrorMessage)
        authorizer.result = .success(URL(string: "convolab://study-time?calendarConnection=connected")!)
        service.statusError = URLError(.timedOut); await store.connectGoogleCalendar()
        XCTAssertEqual(store.googleCalendarStatus?.connected, true)
    }

    func testOAuthCancellationDoesNotShowAnError() async throws {
        let cancellation = NSError(domain: ASWebAuthenticationSessionError.errorDomain, code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue)
        XCTAssertNil(googleCalendarFriendlyMessage(for: cancellation))
    }

    func testStatusResponseFromPreviousAccountIsIgnored() async throws {
        let service = TestGoogleCalendarConnectionService()
        let store = try makeStore(
            service: service,
            authorizer: TestGoogleCalendarAuthorizer(result: .failure(URLError(.cancelled)))
        )
        store.activate(userID: 41)
        service.pauseStatus = true
        let load = Task { await store.loadGoogleCalendarConnection() }
        while service.statusContinuation == nil { await Task.yield() }

        store.activate(userID: 42)
        service.resumeStatus()
        await load.value

        XCTAssertNil(store.googleCalendarStatus)
        XCTAssertFalse(store.googleCalendarIsLoading)
    }

    private func makeStore(
        service: TestGoogleCalendarConnectionService,
        authorizer: TestGoogleCalendarAuthorizer
    ) throws -> StudyTimeStore {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        Self.retainedContainers.append(container)
        return StudyTimeStore(
            api: makeClient { _ in throw URLError(.unsupportedURL) },
            context: container.mainContext,
            googleCalendar: service,
            googleCalendarAuthorizer: authorizer
        )
    }

    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: configuration))
    }
}

@MainActor
private final class TestGoogleCalendarConnectionService: GoogleCalendarConnectionServing {
    let authorizationURLValue = URL(string: "https://accounts.google.com/oauth")!
    var statusResponse = GoogleCalendarConnectionStatus(
        connected: false, accountEmail: nil, scopes: [], settings: nil,
        connectedAt: nil, lastSyncedAt: nil
    )
    var disconnectCount = 0
    var pauseStatus = false
    var statusError: Error?
    var statusContinuation: CheckedContinuation<GoogleCalendarConnectionStatus, Never>?

    func status() async throws -> GoogleCalendarConnectionStatus {
        if let statusError { throw statusError }
        guard pauseStatus else { return statusResponse }
        return await withCheckedContinuation { statusContinuation = $0 }
    }
    func authorizationURL() async throws -> URL { authorizationURLValue }
    func calendars() async throws -> GoogleCalendarListResponse { .init(calendars: [], truncated: false) }
    func updateSettings(_ settings: GoogleCalendarSettings) async throws -> GoogleCalendarSettings { settings }
    func disconnect() async throws { disconnectCount += 1 }

    func resumeStatus() {
        statusContinuation?.resume(returning: statusResponse)
        statusContinuation = nil
    }
}

@MainActor
private final class TestGoogleCalendarAuthorizer: GoogleCalendarAuthorizing {
    var result: Result<URL, Error>
    private(set) var openedURLs: [URL] = []

    init(result: Result<URL, Error>) { self.result = result }

    func authorize(at url: URL) async throws -> URL {
        openedURLs.append(url)
        return try result.get()
    }
}

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
                        #"{"connected":true,"accountEmail":"andrew@example.com","connectedAt":"2026-08-15T14:00:00Z","lastSyncedAt":"2026-08-15T14:11:12Z"}"#.utf8
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
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                throw URLError(.badURL)
            }
        }
        let service = LiveGoogleCalendarConnectionService(api: api)
        let status = try await service.status()
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.accountEmail, "andrew@example.com")
        XCTAssertNotNil(status.lastSyncedAt)
        let authorizationURL = try await service.authorizationURL()
        XCTAssertEqual(authorizationURL.absoluteString, "https://accounts.google.com/oauth")
        try await service.disconnect()
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
        XCTAssertNil(store.googleCalendarErrorMessage)
        XCTAssertFalse(store.googleCalendarIsWorking)
        await store.disconnectGoogleCalendar()
        XCTAssertEqual(service.disconnectCount, 1)
        XCTAssertEqual(store.googleCalendarStatus?.connected, false)
    }

    func testConnectionFailureShowsControlledMessageAndCanRetryStatus() async throws {
        let service = TestGoogleCalendarConnectionService()
        let denied = URL(string: "convolab://study-time?calendarConnection=error&reason=access_denied")!
        let authorizer = TestGoogleCalendarAuthorizer(result: .success(denied))
        let store = try makeStore(service: service, authorizer: authorizer)
        store.activate(userID: 42)
        await store.connectGoogleCalendar()
        XCTAssertEqual(store.googleCalendarErrorMessage, "Google Calendar access wasn’t granted.")
        service.statusResponse = .init(connected: false, accountEmail: nil, connectedAt: nil, lastSyncedAt: nil)
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
    var statusResponse = GoogleCalendarConnectionStatus(connected: false, accountEmail: nil, connectedAt: nil, lastSyncedAt: nil)
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

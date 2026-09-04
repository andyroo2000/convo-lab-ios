import AuthenticationServices
import UIKit

struct GoogleCalendarConnectionStatus: nonisolated Decodable, Equatable, Sendable {
    let connected: Bool
    let accountEmail: String?
    let scopes: [String]
    let settings: GoogleCalendarSettings?
    let connectedAt: Date?
    let lastSyncedAt: Date?
    let sync: GoogleCalendarSyncState?
    let nextLesson: GoogleCalendarNextLesson?

    init(
        connected: Bool,
        accountEmail: String?,
        scopes: [String],
        settings: GoogleCalendarSettings?,
        connectedAt: Date?,
        lastSyncedAt: Date?,
        sync: GoogleCalendarSyncState? = nil,
        nextLesson: GoogleCalendarNextLesson? = nil
    ) {
        self.connected = connected
        self.accountEmail = accountEmail
        self.scopes = scopes
        self.settings = settings
        self.connectedAt = connectedAt
        self.lastSyncedAt = lastSyncedAt
        self.sync = sync
        self.nextLesson = nextLesson
    }
}

struct GoogleCalendarNextLesson: nonisolated Decodable, Equatable, Sendable {
    let title: String
    let startsAt: Date
    let endsAt: Date
}

enum GoogleCalendarSyncPhase: String, nonisolated Decodable, Equatable, Sendable {
    case idle, queued, running, succeeded, failed

    var isActive: Bool { self == .queued || self == .running }
}

struct GoogleCalendarSyncState: nonisolated Decodable, Equatable, Sendable {
    let status: GoogleCalendarSyncPhase
    let errorCode: String?
    let statusAt: Date?
}

struct GoogleCalendarSettings: nonisolated Codable, Equatable, Sendable {
    let calendarIds: [String]
    let titleMatchTerms: [String]
    let syncEnabled: Bool
}

struct GoogleCalendar: nonisolated Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let primary: Bool
}

struct GoogleCalendarListResponse: nonisolated Decodable, Equatable, Sendable {
    let calendars: [GoogleCalendar]
    let truncated: Bool
}

struct GoogleCalendarPreviewRequest: Encodable, Equatable {
    let calendarIds: [String]
    let titleMatchTerms: [String]
}

struct GoogleCalendarPreviewResponse: nonisolated Decodable, Equatable, Sendable {
    let generatedAt: Date
    let startsAt: Date
    let endsAt: Date
    let scannedEventCount: Int
    let matchedEventCount: Int
    let truncated: Bool
    let matches: [GoogleCalendarPreviewMatch]
}

struct GoogleCalendarPreviewMatch: nonisolated Decodable, Equatable, Sendable {
    let calendarId: String
    let calendarName: String
    let title: String
    let startsAt: Date
    let endsAt: Date
    let durationMs: Int64
    let matchedTerms: [String]
    let alreadySynced: Bool

    var statusLabel: String { alreadySynced ? "Already imported" : "Eligible" }
    var matchReason: String { "Matched: \(matchedTerms.joined(separator: ", "))" }
}

struct GoogleCalendarSettingsDraft: Equatable {
    private struct CanonicalizationRule {
        let allowedCount: ClosedRange<Int>
        let countError: GoogleCalendarSettingsValidationError
        let validate: (String) throws -> Void
        let comparisonKey: (String) -> String
    }

    var calendarIds: [String]
    var titleMatchTerms: [String]
    var syncEnabled: Bool

    func canonicalized() throws -> GoogleCalendarSettings {
        let calendarIds = try Self.canonicalizedCalendarIDs(calendarIds)
        let titleMatchTerms = try Self.canonicalizedTerms(titleMatchTerms)
        return GoogleCalendarSettings(
            calendarIds: calendarIds,
            titleMatchTerms: titleMatchTerms,
            syncEnabled: syncEnabled
        )
    }

    static func canonicalizedCalendarIDs(_ values: [String]) throws -> [String] {
        try canonicalizedValues(values, using: CanonicalizationRule(
            allowedCount: 1...25,
            countError: .calendarCount,
            validate: { value in
                guard !value.isEmpty else { throw GoogleCalendarSettingsValidationError.emptyCalendarID }
                guard value.count <= 1_024 else { throw GoogleCalendarSettingsValidationError.calendarIDTooLong }
            },
            comparisonKey: { $0 }
        ))
    }

    static func canonicalizedTerms(_ values: [String]) throws -> [String] {
        try canonicalizedValues(values, using: CanonicalizationRule(
            allowedCount: 1...50,
            countError: .termCount,
            validate: { value in
                guard !value.isEmpty else { throw GoogleCalendarSettingsValidationError.emptyTerm }
                guard value.unicodeScalars.count <= 100 else {
                    throw GoogleCalendarSettingsValidationError.termTooLong
                }
            },
            comparisonKey: termComparisonKey
        ))
    }

    private static func canonicalizedValues(
        _ values: [String],
        using rule: CanonicalizationRule
    ) throws -> [String] {
        guard rule.allowedCount.contains(values.count) else { throw rule.countError }
        var seen = Set<String>()
        return try values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            try rule.validate(value)
            return seen.insert(rule.comparisonKey(value)).inserted ? value : nil
        }
    }

    static func termComparisonKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

enum GoogleCalendarSettingsValidationError: LocalizedError, Equatable {
    case calendarCount
    case emptyCalendarID
    case calendarIDTooLong
    case termCount
    case emptyTerm
    case termTooLong

    var errorDescription: String? {
        switch self {
        case .calendarCount: "Choose between 1 and 25 calendars."
        case .emptyCalendarID: "A selected calendar is invalid. Refresh your calendars and try again."
        case .calendarIDTooLong: "A selected calendar identifier is too long."
        case .termCount: "Add between 1 and 50 title-match terms."
        case .emptyTerm: "Title-match terms can’t be blank."
        case .termTooLong: "Title-match terms can’t exceed 100 characters."
        }
    }
}

struct GoogleCalendarAuthorizationRequest: Encodable, Equatable {
    let completionTarget = "ios"
}

struct GoogleCalendarAuthorizationResponse: nonisolated Decodable, Equatable, Sendable {
    let authorizationUrl: URL
}

protocol GoogleCalendarConnectionServing {
    func status() async throws -> GoogleCalendarConnectionStatus
    func authorizationURL() async throws -> URL
    func calendars() async throws -> GoogleCalendarListResponse
    func preview(_ request: GoogleCalendarPreviewRequest) async throws -> GoogleCalendarPreviewResponse
    func updateSettings(_ settings: GoogleCalendarSettings) async throws -> GoogleCalendarSettings
    func sync() async throws -> GoogleCalendarConnectionStatus
    func disconnect() async throws
}

final class LiveGoogleCalendarConnectionService: GoogleCalendarConnectionServing {
    private enum Endpoint {
        static let connection = "/api/study/google-calendar"
        static let connect = "/api/study/google-calendar/connect"
        static let calendars = "/api/study/google-calendar/calendars"
        static let preview = "/api/study/google-calendar/preview"
        static let settings = "/api/study/google-calendar/settings"
        static let sync = "/api/study/google-calendar/sync"
    }

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func status() async throws -> GoogleCalendarConnectionStatus {
        do {
            return try await api.request(Endpoint.connection)
        } catch {
            throw mapGoogleCalendarAPIError(error)
        }
    }

    func authorizationURL() async throws -> URL {
        let response: GoogleCalendarAuthorizationResponse = try await api.request(
            Endpoint.connect,
            method: "POST",
            body: GoogleCalendarAuthorizationRequest()
        )
        guard response.authorizationUrl.scheme == "https" else {
            throw GoogleCalendarConnectionError.invalidAuthorizationURL
        }
        return response.authorizationUrl
    }

    func calendars() async throws -> GoogleCalendarListResponse {
        do {
            return try await api.request(Endpoint.calendars)
        } catch {
            throw mapGoogleCalendarAPIError(error)
        }
    }

    func preview(_ request: GoogleCalendarPreviewRequest) async throws -> GoogleCalendarPreviewResponse {
        do {
            return try await api.request(Endpoint.preview, method: "POST", body: request)
        } catch {
            throw mapGoogleCalendarAPIError(error)
        }
    }

    func updateSettings(_ settings: GoogleCalendarSettings) async throws -> GoogleCalendarSettings {
        do {
            return try await api.request(
                Endpoint.settings,
                method: "PUT",
                body: settings
            )
        } catch {
            throw mapGoogleCalendarAPIError(error)
        }
    }

    func sync() async throws -> GoogleCalendarConnectionStatus {
        do {
            return try await api.request(Endpoint.sync, method: "POST")
        } catch {
            throw mapGoogleCalendarAPIError(error)
        }
    }

    func disconnect() async throws {
        try await api.request(Endpoint.connection, method: "DELETE")
    }
}

protocol GoogleCalendarAuthorizing: AnyObject {
    func authorize(at url: URL) async throws -> URL
}

enum GoogleCalendarConnectionError: LocalizedError, Equatable {
    case invalidAuthorizationURL
    case invalidCallback
    case authorizationInProgress
    case connectionFailed(reason: String?)
    case notConnected
    case invalidSettings
    case rateLimited
    case providerUnavailable
    case sessionExpired
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL, .invalidCallback:
            "Google Calendar returned an invalid connection response. Please try again."
        case .authorizationInProgress:
            "A Google Calendar connection is already in progress."
        case let .connectionFailed(reason):
            switch reason {
            case "access_denied":
                "Google Calendar access wasn’t granted."
            case "expired", "invalid_state", "state_mismatch":
                "The Google Calendar connection expired. Please try again."
            default:
                "Google Calendar couldn’t be connected. Please try again."
            }
        case .notConnected:
            "Connect or reconnect Google Calendar, then try again."
        case .invalidSettings:
            "Those calendar settings aren’t valid. Review them and try again."
        case .rateLimited:
            "Google Calendar is receiving too many requests. Please wait and try again."
        case .providerUnavailable:
            "Google Calendar is temporarily unavailable. Please try again later."
        case .sessionExpired:
            "Your session expired. Sign in again, then retry."
        case .requestFailed:
            "Something went wrong with Google Calendar. Please try again."
        }
    }
}

private func mapGoogleCalendarAPIError(_ error: Error) -> Error {
    guard case let APIClientError.rejected(status, _) = error else { return error }
    return switch status {
    case 401: GoogleCalendarConnectionError.sessionExpired
    case 409: GoogleCalendarConnectionError.notConnected
    case 422: GoogleCalendarConnectionError.invalidSettings
    case 429: GoogleCalendarConnectionError.rateLimited
    case 502, 503: GoogleCalendarConnectionError.providerUnavailable
    default: GoogleCalendarConnectionError.requestFailed
    }
}

struct GoogleCalendarCallback: Equatable {
    let connected: Bool
    let reason: String?

    static func parse(_ url: URL) throws -> Self {
        guard url.scheme?.lowercased() == "convolab",
              url.host?.lowercased() == "study-time",
              url.path.isEmpty || url.path == "/",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let result = components.queryItems?.first(where: {
                  $0.name == "calendarConnection"
              })?.value
        else {
            throw GoogleCalendarConnectionError.invalidCallback
        }
        let reason = components.queryItems?.first(where: { $0.name == "reason" })?.value
        switch result {
        case "connected":
            return Self(connected: true, reason: nil)
        case "error":
            return Self(connected: false, reason: reason)
        default:
            throw GoogleCalendarConnectionError.invalidCallback
        }
    }
}

final class LiveGoogleCalendarAuthorizer: NSObject, GoogleCalendarAuthorizing,
    ASWebAuthenticationPresentationContextProviding
{
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    private var attemptID: UUID?

    func authorize(at url: URL) async throws -> URL {
        guard session == nil else {
            throw GoogleCalendarConnectionError.authorizationInProgress
        }
        guard let anchor = Self.activeAnchor() else {
            throw GoogleCalendarConnectionError.invalidCallback
        }
        let attemptID = UUID()
        self.attemptID = attemptID
        self.anchor = anchor
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "convolab"
            ) { [weak self] callbackURL, error in
                if self?.attemptID == attemptID {
                    self?.session = nil; self?.anchor = nil
                    self?.attemptID = nil
                }
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? GoogleCalendarConnectionError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                if self.attemptID == attemptID {
                    self.session = nil; self.anchor = nil
                    self.attemptID = nil
                }
                continuation.resume(throwing: GoogleCalendarConnectionError.invalidCallback)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? Self.activeAnchor() ?? ASPresentationAnchor()
    }

    private static func activeAnchor() -> ASPresentationAnchor? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

func googleCalendarFriendlyMessage(for error: Error) -> String? {
    let cocoaError = error as NSError
    if cocoaError.domain == ASWebAuthenticationSessionError.errorDomain,
       cocoaError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
    {
        return nil
    }
    if let error = error as? GoogleCalendarConnectionError {
        return error.localizedDescription
    }
    if error is URLError {
        return "Couldn’t reach ConvoLab. Check your connection and try again."
    }
    if case APIClientError.rejected(status: 401, message: _) = error {
        return "Your session expired. Sign in again, then retry."
    }
    return "Couldn’t update Google Calendar. Please try again."
}

import AuthenticationServices
import UIKit

struct GoogleCalendarConnectionStatus: Decodable, Equatable {
    let connected: Bool
    let accountEmail: String?
    let connectedAt: Date?
    let lastSyncedAt: Date?
}

struct GoogleCalendarAuthorizationRequest: Encodable, Equatable {
    let completionTarget = "ios"
}

struct GoogleCalendarAuthorizationResponse: Decodable, Equatable {
    let authorizationUrl: URL
}

protocol GoogleCalendarConnectionServing {
    func status() async throws -> GoogleCalendarConnectionStatus
    func authorizationURL() async throws -> URL
    func disconnect() async throws
}

final class LiveGoogleCalendarConnectionService: GoogleCalendarConnectionServing {
    private enum Endpoint {
        static let connection = "/api/study/google-calendar"
        static let connect = "/api/study/google-calendar/connect"
    }

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func status() async throws -> GoogleCalendarConnectionStatus {
        try await api.request(Endpoint.connection)
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
    case connectionFailed(reason: String?)

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL, .invalidCallback:
            "Google Calendar returned an invalid connection response. Please try again."
        case let .connectionFailed(reason):
            switch reason {
            case "access_denied":
                "Google Calendar access wasn’t granted."
            case "expired", "invalid_state", "state_mismatch":
                "The Google Calendar connection expired. Please try again."
            default:
                "Google Calendar couldn’t be connected. Please try again."
            }
        }
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

    func authorize(at url: URL) async throws -> URL {
        guard let anchor = Self.activeAnchor() else {
            throw GoogleCalendarConnectionError.invalidCallback
        }
        self.anchor = anchor
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "convolab"
            ) { [weak self] callbackURL, error in
                self?.session = nil
                self?.anchor = nil
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
                self.session = nil
                self.anchor = nil
                continuation.resume(throwing: GoogleCalendarConnectionError.invalidCallback)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor!
    }

    private static func activeAnchor() -> ASPresentationAnchor? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.first.map { ASPresentationAnchor(windowScene: $0) }
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

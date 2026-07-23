import Foundation

enum APIClientError: LocalizedError {
    case invalidResponse
    case rejected(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The server returned an invalid response."
        case let .rejected(_, message):
            message
        }
    }
}

@Observable
final class APIClient {
    private let baseURL: URL
    private let session: URLSession
    private(set) var accessToken: String?

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func setAccessToken(_ token: String?) {
        accessToken = token
    }

    func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        response: Response.Type = Response.self
    ) async throws -> Response {
        var components = URLComponents(
            url: baseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query
        }
        guard let url = components?.url else {
            throw APIClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try Self.encoder.encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, urlResponse) = try await session.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let message = (try? Self.decoder.decode(ErrorPayload.self, from: data).message)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw APIClientError.rejected(status: httpResponse.statusCode, message: message)
        }

        if data.isEmpty, Response.self == IgnoredResponse.self {
            return IgnoredResponse() as! Response
        }
        return try Self.decoder.decode(Response.self, from: data)
    }

    func download(_ rawURL: URL) async throws -> (URL, URLResponse) {
        let url = rawURL.scheme == nil ? baseURL.appending(path: rawURL.path) : rawURL
        var request = URLRequest(url: url)
        if let accessToken, isSameOrigin(url, baseURL) {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (temporaryURL, response) = try await session.download(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            200..<300 ~= httpResponse.statusCode
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIClientError.rejected(
                status: status,
                message: status == 0
                    ? "The media server returned an invalid response."
                    : HTTPURLResponse.localizedString(forStatusCode: status)
            )
        }
        return (temporaryURL, response)
    }

    private func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased()
        else {
            return false
        }

        func effectivePort(for url: URL) -> Int? {
            url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        }
        return effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    private struct ErrorPayload: Decodable {
        let message: String
    }

    private struct AnyEncodable: Encodable {
        private let encodeValue: (Encoder) throws -> Void

        init(_ value: any Encodable) {
            encodeValue = { encoder in
                try value.encode(to: encoder)
            }
        }

        func encode(to encoder: Encoder) throws {
            try encodeValue(encoder)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = fractional.date(from: value) ?? standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return decoder
    }()
}

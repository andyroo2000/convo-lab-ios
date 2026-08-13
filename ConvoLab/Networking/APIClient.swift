import Foundation

enum APIClientError: LocalizedError {
    case invalidResponse
    case rejected(status: Int, message: String)
    case decoding(path: String, details: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The server returned an invalid response."
        case let .rejected(_, message):
            message
        case let .decoding(path, details):
            "The server response for \(path) couldn’t be read: \(details)"
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
        timeout: TimeInterval = 45,
        authorizationToken: String? = nil,
        response: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await sendRequest(
            path,
            method: method,
            query: query,
            body: body,
            timeout: timeout,
            authorizationToken: authorizationToken
        )
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch let error as DecodingError {
            let details = Self.decodingDetails(error)
            print("API decoding failed for \(path): \(details)")
            throw APIClientError.decoding(path: path, details: details)
        }
    }

    func request(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        timeout: TimeInterval = 45
    ) async throws {
        _ = try await sendRequest(
            path,
            method: method,
            query: query,
            body: body,
            timeout: timeout
        )
    }

    private func sendRequest(
        _ path: String,
        method: String,
        query: [URLQueryItem],
        body: (any Encodable)?,
        timeout: TimeInterval,
        authorizationToken: String? = nil
    ) async throws -> Data {
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
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = authorizationToken ?? accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        return data
    }

    func download(_ rawURL: URL) async throws -> (URL, URLResponse) {
        let url: URL
        if rawURL.scheme == nil {
            guard let resolved = URL(
                string: rawURL.relativeString,
                relativeTo: baseURL
            )?.absoluteURL else {
                throw APIClientError.invalidResponse
            }
            url = resolved
        } else {
            url = rawURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        if let accessToken, isSameOrigin(url, baseURL) {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        var rateLimitRetry = 0
        while true {
            let (temporaryURL, response) = try await session.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIClientError.rejected(
                    status: 0,
                    message: "The media server returned an invalid response."
                )
            }
            if httpResponse.statusCode == 429, rateLimitRetry < 3 {
                try? FileManager.default.removeItem(at: temporaryURL)
                let delay = Self.rateLimitRetryDelay(
                    response: httpResponse,
                    retry: rateLimitRetry
                )
                rateLimitRetry += 1
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard 200..<300 ~= httpResponse.statusCode else {
                throw APIClientError.rejected(
                    status: httpResponse.statusCode,
                    message: HTTPURLResponse.localizedString(
                        forStatusCode: httpResponse.statusCode
                    )
                )
            }
            return (temporaryURL, response)
        }
    }

    func upload<Response: Decodable>(
        _ path: String,
        fields: [String: String],
        fileData: Data,
        fileField: String,
        fileName: String,
        mimeType: String,
        timeout: TimeInterval = 90,
        response: Response.Type = Response.self
    ) async throws -> Response {
        let url = baseURL.appending(
            path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )

        let boundary = "ConvoLab-\(UUID().uuidString)"
        var body = Data()
        func append(_ value: String) {
            body.append(Data(value.utf8))
        }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n"
        )
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch let error as DecodingError {
            let details = Self.decodingDetails(error)
            print("API decoding failed for \(path): \(details)")
            throw APIClientError.decoding(path: path, details: details)
        }
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

    private static func rateLimitRetryDelay(
        response: HTTPURLResponse,
        retry: Int
    ) -> TimeInterval {
        if let rawValue = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(rawValue.trimmingCharacters(in: .whitespaces)),
           seconds >= 0 {
            // A small cushion prevents retrying just before the server's fixed
            // rate-limit window has actually rolled over.
            return min(seconds + 0.25, 120)
        }
        return [5, 15, 45][min(retry, 2)]
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
        encoder.dateEncodingStrategy = .custom(ISO8601Milliseconds.encode)
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(ISO8601Milliseconds.decode)
        return decoder
    }()

    private static func decodingDetails(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, context):
            "missing \(codingPath(context.codingPath, appending: key))"
        case let .valueNotFound(_, context):
            "missing value at \(codingPath(context.codingPath))"
        case let .typeMismatch(_, context):
            "unexpected value at \(codingPath(context.codingPath))"
        case let .dataCorrupted(context):
            "invalid value at \(codingPath(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            "unknown decoding error"
        }
    }

    private static func codingPath(
        _ codingPath: [any CodingKey],
        appending key: (any CodingKey)? = nil
    ) -> String {
        let keys = codingPath + (key.map { [$0] } ?? [])
        guard !keys.isEmpty else { return "response root" }
        return keys.map { codingKey in
            if let index = codingKey.intValue {
                return "[\(index)]"
            }
            return codingKey.stringValue
        }
        .joined(separator: ".")
        .replacingOccurrences(of: ".[", with: "[")
    }
}

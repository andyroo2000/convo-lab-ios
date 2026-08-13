import Foundation

enum ISO8601Milliseconds {
    nonisolated private static let formatStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )

    nonisolated static func canonicalDate(_ date: Date) -> Date {
        // Flooring the Unix millisecond value is equivalent to truncating the
        // fractional digits of a UTC timestamp, including before the epoch.
        Date(
            timeIntervalSince1970: (
                date.timeIntervalSince1970 * 1_000
            ).rounded(.down) / 1_000
        )
    }

    nonisolated static func string(from date: Date) -> String {
        formatStyle.format(canonicalDate(date))
    }

    nonisolated static func date(from value: String) -> Date? {
        try? formatStyle.parse(value)
    }

    nonisolated static func encode(_ date: Date, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string(from: date))
    }

    nonisolated static func decode(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let date = date(from: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return date
    }
}

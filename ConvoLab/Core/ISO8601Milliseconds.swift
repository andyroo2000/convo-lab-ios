import Foundation

enum ISO8601Milliseconds {
    nonisolated private static let formatters = Formatters()

    nonisolated static func canonicalDate(_ date: Date) -> Date {
        // Flooring the Unix millisecond value is equivalent to truncating the
        // fractional digits of a UTC timestamp, including before the epoch.
        // ISO8601DateFormatter can parse an exact millisecond a few nanoseconds
        // below its Double boundary, so snap only that representation noise.
        let milliseconds = date.timeIntervalSince1970 * 1_000
        let nearestMillisecond = milliseconds.rounded()
        let representationTolerance = max(0.000_1, milliseconds.ulp * 2)
        let canonicalMilliseconds = if
            abs(milliseconds - nearestMillisecond) <= representationTolerance
        {
            nearestMillisecond
        } else {
            milliseconds.rounded(.down)
        }
        return Date(
            timeIntervalSince1970: canonicalMilliseconds / 1_000
        )
    }

    nonisolated static func string(from date: Date) -> String {
        formatters.string(from: canonicalDate(date))
    }

    nonisolated static func date(from value: String) -> Date? {
        formatters.date(from: value)
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

private final class Formatters: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private let fractional: ISO8601DateFormatter
    nonisolated(unsafe) private let standard: ISO8601DateFormatter

    nonisolated init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
    }

    nonisolated func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractional.string(from: date)
    }

    nonisolated func date(from value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: value) ?? standard.date(from: value)
    }
}

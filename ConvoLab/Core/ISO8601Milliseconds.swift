import Foundation

enum ISO8601Milliseconds {
    nonisolated private static let formatters = Formatters()
    nonisolated(unsafe) private static let strictTimestampExpression = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|([+-])(\d{2}):(\d{2}))$"#
    )

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
        guard isStrictTimestamp(value) else { return nil }
        return formatters.date(from: value)
    }

    nonisolated private static func isStrictTimestamp(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = strictTimestampExpression.firstMatch(in: value, range: range) else {
            return false
        }
        func integer(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
        guard
            let year = integer(1),
            let month = integer(2),
            let day = integer(3),
            let hour = integer(4),
            let minute = integer(5),
            let second = integer(6),
            (1...12).contains(month),
            (1...31).contains(day),
            hour <= 23,
            minute <= 59,
            second <= 59,
            DateComponents(year: year, month: month, day: day).isValidDate(
                in: Calendar(identifier: .gregorian)
            )
        else {
            return false
        }
        guard let offsetHour = integer(8), let offsetMinute = integer(9) else {
            return true
        }
        guard let signRange = Range(match.range(at: 7), in: value) else { return false }
        let sign = value[signRange] == "-" ? -1 : 1
        let offset = sign * ((offsetHour * 60) + offsetMinute)
        return offsetMinute <= 59 && (-720...840).contains(offset)
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

import Foundation

@MainActor
enum JournalDates {
    static let storage: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func heading(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: ".")
    }

    static func notebook(_ value: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: value), parser.string(from: date) == value else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy年M月d日（E）"
        return formatter.string(from: date)
    }

    static func display(_ value: String) -> String {
        guard let date = storage.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

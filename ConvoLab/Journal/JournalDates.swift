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

    static func display(_ value: String) -> String {
        guard let date = storage.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

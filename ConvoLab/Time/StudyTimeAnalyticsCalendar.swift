import Foundation

struct StudyTimeAnalyticsCalendar: Equatable {
    let timeZone: TimeZone
    let weekStartsOn: Int

    init(timeZone: TimeZone = .current, weekStartsOn: Int = 2) {
        self.timeZone = timeZone
        self.weekStartsOn = weekStartsOn
    }

    var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = timeZone
        result.firstWeekday = weekStartsOn
        return result
    }

    func anchor(_ date: Date) -> String { formatter.string(from: date) }
    func date(_ anchor: String) -> Date? { formatter.date(from: anchor) }

    func bounds(_ range: StudyTimeRange, anchor: Date) -> DateInterval? {
        let unit: Calendar.Component = switch range {
        case .today: .day
        case .week: .weekOfYear
        case .month: .month
        case .year, .all: .year
        }
        return calendar.dateInterval(of: unit, for: anchor)
    }

    private var formatter: DateFormatter {
        let result = DateFormatter()
        result.calendar = calendar
        result.locale = Locale(identifier: "en_US_POSIX")
        result.timeZone = timeZone
        result.dateFormat = "yyyy-MM-dd"
        return result
    }
}

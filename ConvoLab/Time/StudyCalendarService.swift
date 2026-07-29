import EventKit
import Foundation

private enum StudyCalendarError: LocalizedError {
    case accessDenied
    case noDefaultCalendar

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Calendar access is required to add this study entry."
        case .noDefaultCalendar:
            "Choose a writable default calendar in Calendar settings, then try again."
        }
    }
}

enum StudyCalendarService {
    @MainActor
    static func addEvent(title: String, start: Date, end: Date) async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw StudyCalendarError.accessDenied
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw StudyCalendarError.noDefaultCalendar
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        event.notes = "Logged with ConvoLab study time."
        try store.save(event, span: .thisEvent)
    }
}

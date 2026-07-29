import EventKit
import Foundation

private enum StudyCalendarError: LocalizedError {
    case accessDenied
    case noDefaultCalendar
    case eventNotFound

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Calendar access is required to change this study entry."
        case .noDefaultCalendar:
            "Choose a writable default calendar in Calendar settings, then try again."
        case .eventNotFound:
            "The linked calendar event could not be found."
        }
    }
}

enum StudyCalendarService {
    @MainActor
    static func addEvent(title: String, start: Date, end: Date) async throws -> String {
        let store = try await authorizedStore()
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
        guard let identifier = event.eventIdentifier else {
            throw StudyCalendarError.eventNotFound
        }
        return identifier
    }

    @MainActor
    static func updateEvent(
        identifier: String,
        title: String,
        start: Date,
        end: Date
    ) async throws {
        let store = try await authorizedStore()
        guard let event = store.event(withIdentifier: identifier) else {
            throw StudyCalendarError.eventNotFound
        }
        event.title = title
        event.startDate = start
        event.endDate = end
        try store.save(event, span: .thisEvent)
    }

    @MainActor
    static func deleteEvent(identifier: String) async throws {
        let store = try await authorizedStore()
        guard let event = store.event(withIdentifier: identifier) else { return }
        try store.remove(event, span: .thisEvent)
    }

    @MainActor
    private static func authorizedStore() async throws -> EKEventStore {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw StudyCalendarError.accessDenied
        }
        return store
    }
}

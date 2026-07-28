import EventKit
import Foundation

enum StudyCalendarService {
    @MainActor
    static func addEvent(title: String, start: Date, end: Date) async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw CocoaError(.userCancelled)
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw CocoaError(.fileNoSuchFile)
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

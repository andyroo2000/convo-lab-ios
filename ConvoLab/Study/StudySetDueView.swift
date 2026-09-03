import SwiftUI

struct StudySetDueView: View {
    let onSubmit: (StudyCardSetDueMode, Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customDate = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick options") {
                    Button("Now") {
                        onSubmit(.now, nil)
                    }
                    Button("Tomorrow at 9:00 AM") {
                        onSubmit(.tomorrow, nil)
                    }
                }
                Section("Custom date") {
                    DatePicker(
                        "Due date",
                        selection: $customDate,
                        in: Date.now...Self.maximumCustomDate(),
                        displayedComponents: .date
                    )
                    Button("Set Custom Date") {
                        onSubmit(.customDate, Self.localNineAM(on: customDate))
                    }
                }
            }
            .navigationTitle("Set Due")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    static func localNineAM(
        on date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
    }

    private static func maximumCustomDate(
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let tenYearsFromNow = calendar.date(byAdding: .year, value: 10, to: .now) ?? .distantFuture
        return calendar.date(byAdding: .day, value: -1, to: tenYearsFromNow)
            ?? tenYearsFromNow
    }
}

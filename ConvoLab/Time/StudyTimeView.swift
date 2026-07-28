import SwiftUI

struct StudyTimeView: View {
    let store: StudyTimeStore
    @State private var showingEntry = false
    @State private var selectedActivity: StudyActivityKind = .cardCreation
    @State private var timerName = ""

    private var weekStart: Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
    }

    private var weekSessions: [StudyActivitySession] {
        store.sessions.filter { $0.startedAt >= weekStart }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        metric("Review", category: .review, color: .blue)
                        metric("Create", category: .create, color: .orange)
                        metric("Immerse", category: .immerse, color: .green)
                    }
                } header: {
                    Text("This week")
                } footer: {
                    Text("Only one primary activity runs at a time on this device.")
                }

                Section("Timer") {
                    Picker("Activity", selection: $selectedActivity) {
                        ForEach([
                            StudyActivityKind.cardCreation,
                            .tv,
                            .podcast,
                            .reading,
                            .conversation,
                            .other,
                        ]) { activity in
                            Text(activity.title).tag(activity)
                        }
                    }
                    TextField("Source, show, or project (optional)", text: $timerName)
                    if let active = store.active {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(active.name ?? active.activity.title)
                                        .font(.headline)
                                    Text(
                                        Duration.seconds(
                                            context.date.timeIntervalSince(active.startedAt)
                                        ),
                                        format: .time(pattern: .hourMinuteSecond)
                                    )
                                    .monospacedDigit()
                                    .accessibilityHidden(true)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(active.name ?? active.activity.title)
                                .accessibilityValue("Timer running")
                                Spacer()
                                Button("Stop", role: .destructive) { store.stop() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    } else {
                        Button {
                            store.start(
                                activity: selectedActivity,
                                source: .manual,
                                name: timerName.nilIfBlank
                            )
                        } label: {
                            Label("Start session", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ConvoLabTheme.navy)
                    }
                }

                Section("Recent") {
                    if weekSessions.isEmpty {
                        ContentUnavailableView(
                            "No study time yet",
                            systemImage: "clock",
                            description: Text("Completed activities appear here.")
                        )
                    }
                    ForEach(weekSessions, id: \.stableID) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.name ?? session.activity.title)
                                    .font(.headline)
                                Text(session.startedAt, format: .dateTime.weekday().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(
                                Duration.milliseconds(session.durationMs),
                                format: .time(pattern: .hourMinute)
                            )
                            .monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle("Study Time")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingEntry = true
                    } label: {
                        Label("Add time", systemImage: "calendar.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showingEntry) {
                StudyTimeEntryView(store: store)
            }
            .refreshable {
                await store.synchronize()
            }
            .task {
                await store.synchronize()
            }
        }
    }

    private func metric(
        _ title: String,
        category: StudyActivityCategory,
        color: Color
    ) -> some View {
        let milliseconds = weekSessions
            .filter { $0.category == category }
            .reduce(0) { $0 + $1.durationMs }
        return VStack(spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(
                Duration.milliseconds(milliseconds),
                format: .time(pattern: .hourMinute)
            )
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StudyTimeEntryView: View {
    let store: StudyTimeStore
    @Environment(\.dismiss) private var dismiss
    @State private var activity: StudyActivityKind = .tv
    @State private var name = ""
    @State private var startedAt = Date.now
    @State private var minutes = 30
    @State private var addToCalendar = false
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var entrySaved = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Activity", selection: $activity) {
                    ForEach(StudyActivityKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                TextField("Name", text: $name)
                DatePicker("Started", selection: $startedAt)
                Stepper("\(minutes) minutes", value: $minutes, in: 1...1_440, step: 5)
                Toggle("Add to my calendar", isOn: $addToCalendar)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add Study Time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if entrySaved {
                            dismiss()
                            return
                        }
                        guard !isSaving else { return }
                        isSaving = true
                        errorMessage = nil
                        Task {
                            defer { isSaving = false }
                            do {
                                let calendarWarning = try await store.recordCompleted(
                                    activity: activity,
                                    source: addToCalendar ? .calendar : .manual,
                                    name: name.nilIfBlank,
                                    startedAt: startedAt,
                                    duration: TimeInterval(minutes * 60),
                                    addToCalendar: addToCalendar
                                )
                                if let calendarWarning {
                                    entrySaved = true
                                    errorMessage =
                                        "Study time was saved, but the calendar event was not added. "
                                        + calendarWarning
                                } else {
                                    dismiss()
                                }
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else if entrySaved {
                            Text("Done")
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

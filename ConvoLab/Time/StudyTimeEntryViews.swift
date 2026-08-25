import SwiftUI

struct StudyTimeManualEntrySection: View {
    let store: StudyTimeStore
    let sessions: [StudyActivitySession]
    let reduceMotion: Bool
    @Binding var isExpanded: Bool
    @Binding var selectedActivity: StudyActivityKind
    @Binding var timerName: String
    let onEdit: (StudyActivitySession) -> Void
    let onDelete: (StudyActivitySession) -> Void

    var body: some View {
        Section {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack {
                    Label("Manual Time Entry", systemImage: "clock.badge.plus")
                        .font(.headline)
                        .foregroundStyle(ConvoLabTheme.navy)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(
                isExpanded
                    ? "Hides the timer and editable entries"
                    : "Shows the timer and editable entries"
            )

            if isExpanded {
                StudyTimeTimerRows(
                    store: store,
                    selectedActivity: $selectedActivity,
                    timerName: $timerName
                )
                editableEntryRows
            }
        }
    }

    @ViewBuilder
    private var editableEntryRows: some View {
        Text(StudyTimeEditableEntries.sectionTitle)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)

        if store.editableSessionsIsLoading, sessions.isEmpty {
            HStack {
                Spacer()
                ProgressView("Loading entries…")
                Spacer()
            }
        } else if let message = store.editableSessionsErrorMessage,
                  sessions.isEmpty
        {
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task { await store.loadEditableSessions() }
                }
            }
        } else if sessions.isEmpty {
            ContentUnavailableView(
                StudyTimeEditableEntries.emptyTitle,
                systemImage: "clock.badge",
                description: Text(StudyTimeEditableEntries.emptyDescription)
            )
        }
        ForEach(sessions, id: \.stableID) { session in
            StudyTimeSessionRow(session: session)
                .contentShape(Rectangle())
                .onTapGesture { onEdit(session) }
                .swipeActions(allowsFullSwipe: false) {
                    Button("Delete", role: .destructive) {
                        onDelete(session)
                    }
                    Button("Edit") {
                        onEdit(session)
                    }
                    .tint(ConvoLabTheme.navy)
                }
        }
        if store.editableSessionsNextCursor != nil {
            Button {
                Task { await store.loadEditableSessions(reset: false) }
            } label: {
                HStack {
                    Spacer()
                    if store.editableSessionsIsLoading {
                        ProgressView()
                        Text("Loading…")
                    } else {
                        Text("Load more entries")
                    }
                    Spacer()
                }
                .frame(minHeight: 44)
            }
            .disabled(store.editableSessionsIsLoading)
        }
    }
}

struct StudyTimeSessionRow: View {
    let session: StudyActivitySession

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(session.category.chartColor)
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name ?? session.activity.title)
                    .font(.headline)
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(studyTimeCompactDuration(session.durationMs))
                .monospacedDigit()
        }
    }
}

struct StudyTimeEntryView: View {
    let store: StudyTimeStore
    let session: StudyActivitySession?
    @Environment(\.dismiss) private var dismiss
    @State private var activity: StudyActivityKind
    @State private var name: String
    @State private var startedAt: Date
    @State private var minutes: Int
    @State private var durationWasAdjusted = false
    @State private var addToCalendar = false
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var entrySaved = false

    init(store: StudyTimeStore, session: StudyActivitySession? = nil) {
        self.store = store
        self.session = session
        _activity = State(initialValue: session?.activity ?? .tv)
        _name = State(initialValue: session?.name ?? "")
        _startedAt = State(initialValue: session?.startedAt ?? .now)
        _minutes = State(initialValue: max(1, (session?.durationMs ?? 1_800_000) / 60_000))
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Activity", selection: $activity) {
                    ForEach(StudyActivityKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                TextField("Name", text: $name)
                DatePicker("Started", selection: $startedAt, in: ...Date.now)
                Stepper(
                    "\(minutes) minutes",
                    value: Binding(
                        get: { minutes },
                        set: {
                            minutes = $0
                            durationWasAdjusted = true
                        }
                    ),
                    in: 1...1_440,
                    step: 5
                )
                if session == nil {
                    Toggle("Add to my calendar", isOn: $addToCalendar)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(session == nil ? "Add Study Time" : "Edit Study Time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else if entrySaved {
                            Text("Done")
                        } else {
                            Text(session == nil ? "Add" : "Save")
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func save() {
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
                if let session {
                    let duration = durationWasAdjusted
                        ? TimeInterval(minutes * 60)
                        : TimeInterval(session.durationMs) / 1_000
                    let calendarWarning = try await store.update(
                        session: session,
                        activity: activity,
                        name: name.nilIfBlank,
                        startedAt: startedAt,
                        duration: duration
                    )
                    if let calendarWarning {
                        entrySaved = true
                        errorMessage =
                            "Study time was saved, but the linked calendar event "
                            + "could not be updated. \(calendarWarning)"
                    } else {
                        dismiss()
                    }
                } else {
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
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

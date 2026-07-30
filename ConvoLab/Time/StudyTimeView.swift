import Charts
import SwiftUI

struct StudyTimeView: View {
    let store: StudyTimeStore
    @State private var showingEntry = false
    @State private var editingSession: StudyActivitySession?
    @State private var selectedRange: StudyTimeRange = .week
    @State private var selectedActivity: StudyActivityKind = .cardCreation
    @State private var timerName = ""
    @State private var entryErrorMessage: String?

    private var selectedAnalytics: StudyTimeAnalyticsRange? {
        store.analytics?.range(selectedRange)
    }

    private var manualSessions: [StudyActivitySession] {
        store.sessions.filter { $0.source != .automatic }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Time span", selection: $selectedRange) {
                        ForEach(StudyTimeRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Time span")

                    if let analytics = selectedAnalytics {
                        StudyRhythmChart(
                            analytics: analytics,
                            generatedAt: store.analytics?.generatedAt ?? .now
                        )
                    } else {
                        ProgressView("Loading study rhythm…")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    }
                } header: {
                    Text("Study Rhythm")
                } footer: {
                    Text("Audio drills count as Review. iTalki and other lessons count as Conversation.")
                }

                Section("Timer") {
                    Picker("Activity", selection: $selectedActivity) {
                        ForEach([
                            StudyActivityKind.cardCreation,
                            .tv,
                            .podcast,
                            .reading,
                            .conversation,
                            .wanikaniReview,
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

                if let message = entryErrorMessage ?? store.syncErrorMessage {
                    Section("Sync") {
                        Label(message, systemImage: "exclamationmark.icloud")
                            .foregroundStyle(.red)
                    }
                }

                Section("Manual entries") {
                    if manualSessions.isEmpty {
                        ContentUnavailableView(
                            "No manual entries",
                            systemImage: "clock.badge",
                            description: Text("Timers and added study time appear here.")
                        )
                    }
                    ForEach(manualSessions, id: \.stableID) { session in
                        StudyTimeSessionRow(session: session)
                            .contentShape(Rectangle())
                            .onTapGesture { editingSession = session }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Delete", role: .destructive) {
                                    delete(session)
                                }
                                Button("Edit") {
                                    editingSession = session
                                }
                                .tint(ConvoLabTheme.navy)
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
            .sheet(item: $editingSession) { session in
                StudyTimeEntryView(store: store, session: session)
            }
            .refreshable {
                await store.synchronize()
            }
            .task {
                await store.synchronize()
            }
        }
    }

    private func delete(_ session: StudyActivitySession) {
        entryErrorMessage = nil
        Task {
            do {
                try await store.delete(session: session)
            } catch {
                entryErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct StudyRhythmChart: View {
    let analytics: StudyTimeAnalyticsRange
    let generatedAt: Date

    private var elapsedDayCount: Int {
        let calendar = Calendar.current
        let end = min(generatedAt, analytics.endsAt)
        return max(
            1,
            (calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: analytics.startsAt),
                to: calendar.startOfDay(for: end)
            ).day ?? 0) + 1
        )
    }

    private var bestBucket: StudyTimeAnalyticsBucket? {
        analytics.buckets.max { $0.totalMs < $1.totalMs }
    }

    private var chartDomain: ClosedRange<Date> {
        min(analytics.startsAt, analytics.endsAt)...max(analytics.startsAt, analytics.endsAt)
    }

    private var axisDates: [Date] {
        let step = switch analytics.key {
        case .today: 4
        case .month: 5
        default: 1
        }
        let lastIndex = analytics.buckets.count - 1

        return analytics.buckets.enumerated().compactMap { index, bucket in
            index.isMultiple(of: step) || index == lastIndex ? bucket.startsAt : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                metric("Total", milliseconds: analytics.totalMs)
                metric("Daily avg", milliseconds: analytics.totalMs / elapsedDayCount)
                VStack(spacing: 4) {
                    Text("Best")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(bestBucket.map(bestBucketLabel) ?? "—")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(bestBucket.map { compactDuration($0.totalMs) } ?? "0m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            Chart {
                ForEach(analytics.buckets) { bucket in
                    ForEach(StudyActivityCategory.allCases) { category in
                        let milliseconds = bucket.duration(for: category)
                        if milliseconds > 0 {
                            BarMark(
                                x: .value("Period", bucket.startsAt),
                                y: .value("Minutes", Double(milliseconds) / 60_000)
                            )
                            .foregroundStyle(
                                by: .value("Category", category.title)
                            )
                            .accessibilityLabel(
                                "\(bestBucketLabel(bucket)), \(category.title)"
                            )
                            .accessibilityValue(compactDuration(milliseconds))
                        }
                    }
                }
            }
            .chartForegroundStyleScale(
                domain: StudyActivityCategory.allCases.map(\.title),
                range: StudyActivityCategory.allCases.map(\.chartColor)
            )
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text(axisDuration(minutes))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: axisDates) { value in
                    AxisGridLine()
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(axisLabel(date))
                        }
                    }
                }
            }
            .chartXScale(
                domain: chartDomain,
                range: .plotDimension(padding: 12)
            )
            .frame(height: 210)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(StudyActivityCategory.allCases) { category in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(category.chartColor)
                            .frame(width: 8, height: 8)
                        Text(category.title)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Text(compactDuration(analytics.duration(for: category)))
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func axisLabel(_ date: Date) -> String {
        switch analytics.key {
        case .today:
            date.formatted(.dateTime.hour())
        case .week:
            date.formatted(.dateTime.weekday(.narrow))
        case .month:
            date.formatted(.dateTime.day())
        case .year:
            date.formatted(.dateTime.month(.narrow))
        case .all:
            date.formatted(.dateTime.year())
        }
    }

    private func metric(_ title: String, milliseconds: Int) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(compactDuration(milliseconds))
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func bestBucketLabel(_ bucket: StudyTimeAnalyticsBucket) -> String {
        switch analytics.key {
        case .today:
            bucket.startsAt.formatted(.dateTime.hour())
        case .week:
            bucket.startsAt.formatted(.dateTime.weekday(.abbreviated))
        case .month:
            bucket.startsAt.formatted(.dateTime.day())
        case .year:
            bucket.startsAt.formatted(.dateTime.month(.abbreviated))
        case .all:
            bucket.startsAt.formatted(.dateTime.year())
        }
    }

    private func axisDuration(_ minutes: Double) -> String {
        if minutes >= 60 {
            return "\(Int(minutes / 60))h"
        }
        return "\(Int(minutes))m"
    }
}

private struct StudyTimeSessionRow: View {
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
            Text(compactDuration(session.durationMs))
                .monospacedDigit()
        }
    }
}

private struct StudyTimeEntryView: View {
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

private extension StudyActivityCategory {
    var chartColor: Color {
        switch self {
        case .review: .blue
        case .create: .orange
        case .immerse: .green
        case .conversation: .purple
        case .wanikani: .pink
        }
    }
}

private func compactDuration(_ milliseconds: Int) -> String {
    let totalMinutes = max(0, milliseconds / 60_000)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 {
        return "\(minutes)m"
    }
    if minutes == 0 {
        return "\(hours)h"
    }
    return "\(hours)h \(minutes)m"
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

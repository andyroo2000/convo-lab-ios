import Charts
import SwiftUI

struct StudyTimeView: View {
    let store: StudyTimeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingEntry = false
    @State private var editingSession: StudyActivitySession?
    @State private var selectedRange: StudyTimeRange = .week
    @State private var analyticsDragOffset = CGFloat.zero
    @State private var analyticsCardWidth = CGFloat(360)
    @State private var isSettlingAnalyticsSwipe = false
    @State private var analyticsNavigationGeneration = 0
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
                    .onChange(of: selectedRange) {
                        analyticsNavigationGeneration += 1
                        isSettlingAnalyticsSwipe = false
                        analyticsDragOffset = 0
                        Task { await store.loadAnalytics(anchorDate: .now) }
                    }

                    if let analytics = selectedAnalytics {
                        swipeableAnalytics(analytics)
                    } else {
                        ProgressView("Loading study rhythm…")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    }
                } header: {
                    Text("Study Rhythm")
                } footer: {
                    Text("Audio drills count as Card review. iTalki and other lessons count as Conversation.")
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

    private func swipeableAnalytics(
        _ analytics: StudyTimeAnalyticsRange
    ) -> some View {
        let dragOffset = displayedAnalyticsDragOffset(analytics)
        return ZStack {
            if let previous = adjacentAnalytics(by: -1) {
                analyticsPage(previous.range, generatedAt: previous.generatedAt)
                    .offset(x: -analyticsCardWidth + dragOffset)
                    .accessibilityHidden(true)
            }

            analyticsPage(
                analytics,
                generatedAt: store.analytics?.generatedAt ?? .now
            )
            .offset(x: dragOffset)

            if canNavigateLater(from: analytics),
               let next = adjacentAnalytics(by: 1)
            {
                analyticsPage(next.range, generatedAt: next.generatedAt)
                    .offset(x: analyticsCardWidth + dragOffset)
                    .accessibilityHidden(true)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        analyticsCardWidth = max(geometry.size.width, 1)
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        analyticsCardWidth = max(width, 1)
                    }
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(analyticsSwipeGesture(analytics))
        .task(
            id: "\(store.analytics?.anchorDate ?? "")"
                + "-\(selectedRange.rawValue)-\(store.analyticsCacheGeneration)"
        ) {
            await prefetchAdjacentAnalytics(from: analytics)
        }
        .accessibilityActions {
            if selectedRange != .all {
                Button("Previous period") {
                    navigateAnalytics(by: -1, from: analytics)
                }
                if canNavigateLater(from: analytics) {
                    Button("Next period") {
                        navigateAnalytics(by: 1, from: analytics)
                    }
                }
            }
        }
    }

    private func analyticsPage(
        _ analytics: StudyTimeAnalyticsRange,
        generatedAt: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedRange != .all {
                Text(periodLabel(analytics))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            StudyRhythmChart(analytics: analytics, generatedAt: generatedAt)
        }
    }

    private func adjacentAnalytics(
        by amount: Int
    ) -> (range: StudyTimeAnalyticsRange, generatedAt: Date)? {
        guard let anchor = shiftedAnalyticsAnchor(by: amount),
              let cached = store.cachedAnalytics(anchorDate: anchor),
              let range = cached.range(selectedRange)
        else {
            return nil
        }
        return (range, cached.generatedAt)
    }

    private func prefetchAdjacentAnalytics(
        from analytics: StudyTimeAnalyticsRange
    ) async {
        guard selectedRange != .all else { return }
        if let previousAnchor = shiftedAnalyticsAnchor(by: -1) {
            _ = await store.prefetchAnalytics(anchorDate: previousAnchor)
        }
        if canNavigateLater(from: analytics),
           let nextAnchor = shiftedAnalyticsAnchor(by: 1)
        {
            _ = await store.prefetchAnalytics(anchorDate: nextAnchor)
        }
    }

    private func displayedAnalyticsDragOffset(
        _ analytics: StudyTimeAnalyticsRange
    ) -> CGFloat {
        if analyticsDragOffset < 0, !canNavigateLater(from: analytics) {
            return rubberBand(analyticsDragOffset)
        }
        return analyticsDragOffset
    }

    private func analyticsSwipeGesture(
        _ analytics: StudyTimeAnalyticsRange
    ) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard
                    selectedRange != .all,
                    !isSettlingAnalyticsSwipe,
                    abs(value.translation.width) > abs(value.translation.height)
                else {
                    return
                }
                analyticsDragOffset = value.translation.width
            }
            .onEnded { value in
                guard selectedRange != .all, !isSettlingAnalyticsSwipe else { return }
                let horizontal = value.translation.width
                let predicted = value.predictedEndTranslation.width
                guard abs(horizontal) > abs(value.translation.height) else {
                    snapAnalyticsBack()
                    return
                }

                if max(horizontal, predicted) > 70 {
                    completeAnalyticsSwipe(by: -1)
                } else if min(horizontal, predicted) < -70,
                          canNavigateLater(from: analytics)
                {
                    completeAnalyticsSwipe(by: 1)
                } else {
                    snapAnalyticsBack()
                }
            }
    }

    private func navigateAnalytics(
        by amount: Int,
        from analytics: StudyTimeAnalyticsRange
    ) {
        guard selectedRange != .all else { return }
        if amount > 0, !canNavigateLater(from: analytics) { return }
        completeAnalyticsSwipe(by: amount)
    }

    private func completeAnalyticsSwipe(by amount: Int) {
        guard !isSettlingAnalyticsSwipe,
              let nextAnchor = shiftedAnalyticsAnchor(by: amount)
        else {
            return
        }

        isSettlingAnalyticsSwipe = true
        analyticsNavigationGeneration += 1
        let navigationGeneration = analyticsNavigationGeneration
        let outgoingOffset = amount < 0 ? analyticsCardWidth : -analyticsCardWidth

        Task {
            var ready = store.cachedAnalytics(anchorDate: nextAnchor) != nil
            if !ready {
                ready = await store.prefetchAnalytics(
                    anchorDate: nextAnchor,
                    reportFailure: true
                )
            }
            guard analyticsNavigationGeneration == navigationGeneration else { return }
            guard ready else {
                snapAnalyticsBack()
                isSettlingAnalyticsSwipe = false
                return
            }

            if reduceMotion {
                _ = store.selectCachedAnalytics(anchorDate: nextAnchor)
                analyticsDragOffset = 0
                isSettlingAnalyticsSwipe = false
                return
            }

            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
                analyticsDragOffset = outgoingOffset
            } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    _ = store.selectCachedAnalytics(anchorDate: nextAnchor)
                    analyticsDragOffset = 0
                    isSettlingAnalyticsSwipe = false
                }
            }
        }
    }

    private func snapAnalyticsBack() {
        guard analyticsDragOffset != 0 else { return }
        if reduceMotion {
            analyticsDragOffset = 0
        } else {
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.72)) {
                analyticsDragOffset = 0
            }
        }
    }

    private func shiftedAnalyticsAnchor(by amount: Int) -> Date? {
        let calendar = Calendar.current
        guard let anchorDate = store.analytics?.anchorDate,
              let analyticsAnchor = analyticsAnchorDate(from: anchorDate)
        else {
            return nil
        }
        switch selectedRange {
        case .today:
            return calendar.date(byAdding: .day, value: amount, to: analyticsAnchor)
        case .week:
            return calendar.date(byAdding: .day, value: amount * 7, to: analyticsAnchor)
        case .month:
            guard let start = calendar.dateInterval(of: .month, for: analyticsAnchor)?.start else {
                return nil
            }
            return calendar.date(byAdding: .month, value: amount, to: start)
        case .year:
            guard let start = calendar.dateInterval(of: .year, for: analyticsAnchor)?.start else {
                return nil
            }
            return calendar.date(byAdding: .year, value: amount, to: start)
        case .all:
            return nil
        }
    }

    private func canNavigateLater(from analytics: StudyTimeAnalyticsRange) -> Bool {
        guard selectedRange != .all, let generatedAt = store.analytics?.generatedAt else {
            return false
        }
        return analytics.endsAt <= generatedAt
    }

    private func periodLabel(_ analytics: StudyTimeAnalyticsRange) -> String {
        let inclusiveEnd = analytics.endsAt.addingTimeInterval(-1)
        switch analytics.key {
        case .today:
            return analytics.startsAt.formatted(
                .dateTime.weekday(.wide).month(.wide).day().year()
            )
        case .week:
            return "\(analytics.startsAt.formatted(.dateTime.month(.abbreviated).day()))"
                + " – "
                + inclusiveEnd.formatted(.dateTime.month(.abbreviated).day().year())
        case .month:
            return analytics.startsAt.formatted(.dateTime.month(.wide).year())
        case .year:
            return analytics.startsAt.formatted(.dateTime.year())
        case .all:
            return ""
        }
    }

    private func rubberBand(_ offset: CGFloat) -> CGFloat {
        let magnitude = abs(offset)
        return copysign(42 * (1 - exp(-magnitude / 110)), offset)
    }

    private func analyticsAnchorDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
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
                    Text("\(bestBucket.map { compactDuration($0.totalMs) } ?? "0m") total")
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

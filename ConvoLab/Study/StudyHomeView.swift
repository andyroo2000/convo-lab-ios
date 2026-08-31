import SwiftUI

struct StudyHomeView: View {
    let store: StudyStore
    let player: StudyAudioPlayer
    let timeStore: StudyTimeStore?
    let achievementStore: StudyAchievementStore
    @State private var showingFailedChanges = false
    @State private var interruptedCompletion: StudyAchievementCompletion?
    @State private var newAchievementIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    todayPlan
                    masterySpread
                    StudyAchievementSpotlight(
                        store: achievementStore,
                        newAchievementIDs: newAchievementIDs
                    )
                    readiness

                    if store.cards.isEmpty, store.sessionCounts.hasRemainingReviews {
                        ContentUnavailableView {
                            Label("More cards are ready", systemImage: "rectangle.stack.badge.plus")
                        } description: {
                            Text("Load the next study batch to keep going.")
                        } actions: {
                            Button("Load Next Study Batch") {
                                Task { await store.loadNextReviewBatch() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ConvoLabTheme.navy)
                            .disabled(store.syncStatus == .syncing)
                        }
                        .padding(.vertical, 48)
                    }
                }
                .padding()
            }
            .paperBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await store.synchronize()
                            await achievementStore.refresh()
                            await refreshWaniKaniIfNeeded(force: true)
                            await refreshCalendarIfNeeded(force: true)
                        }
                    } label: {
                        if store.syncStatus == .syncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.trianglehead.2.clockwise")
                        }
                    }
                    .accessibilityLabel("Sync")
                }
            }
            .refreshable {
                await store.synchronize()
                await achievementStore.refresh()
                await refreshWaniKaniIfNeeded(force: true)
                await refreshCalendarIfNeeded(force: true)
            }
            .task {
                if interruptedCompletion == nil {
                    await achievementStore.refresh()
                    interruptedCompletion = achievementStore.prepareInterruptedCompletion()
                }
                // AppModel owns app-wide synchronization. This surface refresh can be
                // cancelled on tab switches and restarted when Study appears again.
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                async let study: Void = refreshStudyIfNeeded()
                async let calendar: Void = refreshCalendarIfNeeded()
                _ = await (study, calendar)
            }
            .sheet(isPresented: $showingFailedChanges) {
                FailedStudyChangesView(store: store)
            }
            .fullScreenCover(item: $interruptedCompletion, onDismiss: {
                interruptedCompletion = nil
            }) { completion in
                NavigationStack {
                    StudySessionView(
                        store: store,
                        player: player,
                        mode: .reviews,
                        timeStore: timeStore,
                        achievementStore: achievementStore,
                        restoredCompletion: completion,
                        onSessionAchievementsLanded: { newAchievementIDs = $0 }
                    )
                }
            }
        }
    }

    private var todayPlan: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                reviewAction

                if let recommendation = store.overview?.learningReadiness,
                   let displayStatus = recommendation.displayStatus,
                   let displaySummary = recommendation.displaySummary,
                   !displayStatus.isEmpty,
                   !displaySummary.isEmpty
                {
                    learningReadinessSummary(
                        status: displayStatus,
                        summary: displaySummary
                    )
                    Divider()
                }

                HStack(spacing: 0) {
                    lessonAction
                    Divider()
                    waniKaniAction
                }
                .fixedSize(horizontal: false, vertical: true)

                if let timeStore,
                   let nextLesson = timeStore.googleCalendarStatus?.nextLesson
                {
                    Divider()
                    NavigationLink {
                        StudyTimeView(store: timeStore, studyStore: store)
                    } label: {
                        nextLessonLabel(nextLesson)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.white.opacity(0.82))
            .clipShape(.rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(ConvoLabTheme.navy.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: ConvoLabTheme.navy.opacity(0.08), radius: 12, y: 5)
        }
    }

    private var reviewAction: some View {
        NavigationLink {
            StudySessionView(
                store: store,
                player: player,
                mode: .reviews,
                timeStore: timeStore,
                achievementStore: achievementStore,
                onSessionAchievementsLanded: { newAchievementIDs = $0 }
            )
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(StudyTodayPresentation.reviewCountText(reviewAvailableCount))
                        .font(.title.bold())
                        .foregroundStyle(ConvoLabTheme.cream)
                    Text(reviewTimeText)
                        .font(.footnote)
                        .foregroundStyle(ConvoLabTheme.cream.opacity(0.72))
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.title3.bold())
                    .foregroundStyle(ConvoLabTheme.navy)
                    .frame(width: 54, height: 54)
                    .background(ConvoLabTheme.cream, in: .circle)
                    .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
                    .accessibilityHidden(true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .background(ConvoLabTheme.navy)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(reviewAvailableCount == 0)
        .accessibilityLabel(
            "Reviews, \(StudyTodayPresentation.reviewCountText(reviewAvailableCount)), \(reviewTimeText)"
        )
    }

    private var lessonAction: some View {
        NavigationLink {
            StudySessionView(
                store: store,
                player: player,
                mode: .lessons,
                timeStore: timeStore,
                achievementStore: achievementStore
            )
        } label: {
            todayTile(
                title: "Lessons",
                detail: StudyTodayPresentation.newCardCountText(store.sessionCounts.newRemaining),
                systemImage: "book.closed.fill",
                color: .green
            )
        }
        .buttonStyle(.plain)
        .disabled(store.sessionCounts.newRemaining == 0)
    }

    private var waniKaniAction: some View {
        NavigationLink {
            WaniKaniBrowserView(timeStore: timeStore)
        } label: {
            todayTile(
                title: "WaniKani",
                detail: store.wanikaniReviewCount.map(StudyTodayPresentation.reviewCountText)
                    ?? "Open reviews",
                systemImage: "character.ja",
                color: ConvoLabTheme.coral
            )
        }
        .buttonStyle(.plain)
    }

    private func todayTile(
        title: String,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(ConvoLabTheme.navy)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .padding(16)
        .contentShape(.rect)
    }

    private func nextLessonLabel(_ lesson: GoogleCalendarNextLesson) -> some View {
        let timing = StudyTodayPresentation.lessonTiming(lesson.startsAt)

        return HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.body.bold())
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(ConvoLabTheme.cyan, in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next lesson")
                    .font(.caption2.bold())
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Text(lesson.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(ConvoLabTheme.navy)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(timing.weekday)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text(timing.date)
                    .font(.caption.bold())
                    .foregroundStyle(ConvoLabTheme.navy)
                Text(timing.time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.trailing)
        }
        .padding(14)
        .contentShape(.rect)
    }

    private var reviewAvailableCount: Int {
        store.sessionCounts.failedDue + store.sessionCounts.reviewRemaining
    }

    private var reviewTimeText: String {
        StudyTodayPresentation.reviewTimeText(reviewCount: reviewAvailableCount)
    }

    private func refreshWaniKaniIfNeeded(force: Bool = false) async {
        guard store.wanikaniConnected else { return }
        guard force || StudyTodayPresentation.shouldRefreshWaniKani(
            reviewCountUpdatedAt: store.wanikaniReviewCountUpdatedAt
        ) else { return }

        await store.syncWaniKani()
    }

    private func refreshStudyIfNeeded() async {
        await store.synchronizeIfNeeded(maxAge: .seconds(60))
        guard !Task.isCancelled else { return }
        await refreshWaniKaniIfNeeded()
    }

    private func refreshCalendarIfNeeded(force: Bool = false) async {
        guard let timeStore else { return }
        guard force || StudyTodayPresentation.shouldRefreshCalendar(
            statusFetchedAt: timeStore.googleCalendarStatusRefreshedAt
        ) else { return }

        await timeStore.loadGoogleCalendarConnection()
    }

    private func learningReadinessSummary(status: String, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status)
                .font(.subheadline.bold())
                .foregroundStyle(ConvoLabTheme.navy)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("StudyLearningReadinessSummary")
    }

    @ViewBuilder
    private var masterySpread: some View {
        if let spread = store.overview?.masterySpread {
            StudyMasterySpreadView(spread: spread)
        }
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Offline readiness", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                Spacer()
                Text(offlineReserveLabel)
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(ConvoLabTheme.cyan.opacity(0.18), in: .capsule)
            }

            let target = store.offlineReadinessTarget
            let prepared = store.offlineReserveIsCurrent
                ? min(store.preparedCardCount, target)
                : 0
            ProgressView(value: Double(prepared), total: Double(max(target, 1)))
                .tint(ConvoLabTheme.cyan)
                .accessibilityLabel("Offline readiness")
                .accessibilityValue(
                    "\(prepared) of \(target) cards ready"
                )

            syncStatus

            if !store.failedStudyChanges.isEmpty {
                Button {
                    showingFailedChanges = true
                } label: {
                    Label(
                        "Review \(store.failedStudyChanges.count) failed \(store.failedStudyChanges.count == 1 ? "change" : "changes")",
                        systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
        .padding()
        .background(.white.opacity(0.72), in: .rect(cornerRadius: 18))
    }

    private var offlineReserveLabel: String {
        guard let days = store.offlineReserveDays else { return "Not synced" }
        guard store.offlineReserveIsCurrent else { return "Expired" }
        return "\(days) \(days == 1 ? "day" : "days")"
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let message = store.storageWriteErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            switch store.syncStatus {
            case .idle:
                if let lastSyncAt = store.lastSyncAt {
                    Text("Last sync: \(lastSyncAt, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .syncing:
                Label("Preparing study media…", systemImage: "arrow.down.circle")
                    .font(.caption)
            case .offline:
                Label("Offline — saved work will sync later", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

}

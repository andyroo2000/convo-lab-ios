import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let user: CurrentUser

    @State private var wanikaniAPIToken = ""
    @State private var confirmingWaniKaniDisconnect = false
    @State private var confirmingCalendarDisconnect = false
    @State private var confirmingClearDownloads = false
    @State private var showingProfileEditor = false
    @State private var showingPasswordEditor = false
    @State private var showingAccountDeletion = false
    @State private var showingFailedStudyChanges = false
    @State private var newCardsPerDay: Int
    @State private var lessonBatchSize: Int
    @State private var reviewTimeBudgetMinutes: Int
    @State private var laneWeights: StudyNewCardLaneWeights?
    @State private var studySettingsSaved = false
    @State private var calendarSettingsModel: GoogleCalendarSettingsModel?

    init(model: AppModel, user: CurrentUser) {
        self.model = model
        self.user = user
        _newCardsPerDay = State(
            initialValue: model.study.studySettings?.newCardsPerDay
                ?? model.study.overview?.newCardsPerDay
                ?? 20
        )
        _lessonBatchSize = State(
            initialValue: model.study.studySettings?.lessonBatchSize
                ?? model.study.overview?.lessonBatchSize
                ?? 5
        )
        let initialReviewTimeBudgetMinutes = model.study.studySettings?.reviewTimeBudgetMinutes
            ?? model.study.overview?.learningReadiness?.reviewTimeBudgetMinutes
            ?? 90
        _reviewTimeBudgetMinutes = State(
            initialValue: min(max(initialReviewTimeBudgetMinutes, 15), 240)
        )
        _laneWeights = State(initialValue: model.study.studySettings?.newCardLaneWeights)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Name", value: user.name)
                    LabeledContent("Email", value: user.email)
                    Button("Edit Profile") {
                        showingProfileEditor = true
                    }
                    Button("Change Password") {
                        showingPasswordEditor = true
                    }
                }

                Section("Offline") {
                    LabeledContent(
                        "Downloaded media",
                        value: ByteCountFormatter.string(
                            fromByteCount: model.mediaCache.totalByteCount,
                            countStyle: .file
                        )
                    )
                    LabeledContent("Study window", value: offlineStudyWindow)
                    Button("Remove Downloaded Media", role: .destructive) {
                        confirmingClearDownloads = true
                    }
                    if model.study.failedStudyChanges.isEmpty {
                        LabeledContent(
                            "Changes needing attention",
                            value: model.study.failedStudyChanges.count.formatted()
                        )
                    } else {
                        Button {
                            showingFailedStudyChanges = true
                        } label: {
                            LabeledContent(
                                "Changes needing attention",
                                value: model.study.failedStudyChanges.count.formatted()
                            )
                        }
                    }
                    Text("Playback positions are stored only on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Stepper(
                        "New cards per day: \(newCardsPerDay)",
                        value: $newCardsPerDay,
                        in: 0...1_000
                    )
                    .onChange(of: newCardsPerDay) {
                        studySettingsSaved = false
                    }
                    Stepper(
                        "Cards per lesson: \(lessonBatchSize)",
                        value: $lessonBatchSize,
                        in: 3...10
                    )
                    .onChange(of: lessonBatchSize) {
                        studySettingsSaved = false
                    }
                    Stepper(
                        "Review budget: \(reviewTimeBudgetMinutes) min",
                        value: $reviewTimeBudgetMinutes,
                        in: 15...240,
                        step: 15
                    )
                    .onChange(of: reviewTimeBudgetMinutes) {
                        studySettingsSaved = false
                    }
                    if let laneWeights {
                        Stepper(
                            "Standard queue: \(laneWeights.standard) (\(laneWeights.percentage(for: laneWeights.standard))%)",
                            value: laneWeightBinding(\.standard),
                            in: 1...20
                        )
                        Stepper(
                            "Lesson follow-up: \(laneWeights.lessonFollowup) (\(laneWeights.percentage(for: laneWeights.lessonFollowup))%)",
                            value: laneWeightBinding(\.lessonFollowup),
                            in: 0...20
                        )
                        Stepper(
                            "WaniKani: \(laneWeights.wanikani) (\(laneWeights.percentage(for: laneWeights.wanikani))%)",
                            value: laneWeightBinding(\.wanikani),
                            in: 0...20
                        )
                        Text(
                            "These are relative weights, not daily limits. Empty lanes automatically give their space to the others."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Button(model.study.isUpdatingStudySettings ? "Saving…" : "Save Study Settings") {
                        Task {
                            studySettingsSaved = await model.study
                                .updateStudySettings(
                                    newCardsPerDay: newCardsPerDay,
                                    lessonBatchSize: lessonBatchSize,
                                    reviewTimeBudgetMinutes: reviewTimeBudgetMinutes,
                                    newCardLaneWeights: laneWeights
                                )
                        }
                    }
                    .disabled(model.study.isUpdatingStudySettings)

                    if studySettingsSaved {
                        Label("Study settings saved", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                    if let error = model.study.studySettingsErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Study")
                } footer: {
                    Text(
                        "The daily limit is your allowance. Cards per lesson controls the preview-and-quiz batch size. Your review budget guides learning-readiness advice; it does not stop reviews."
                    )
                }

                googleCalendarSection

                Section("WaniKani") {
                    if model.study.wanikaniConnected {
                        LabeledContent("WaniKani", value: "Connected")
                        LabeledContent(
                            "Known kanji",
                            value: model.study.knownKanji.count.formatted()
                        )
                        if let lastSyncedAt = model.study.wanikaniLastSyncedAt {
                            LabeledContent(
                                "WaniKani synced",
                                value: lastSyncedAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                        }
                        Toggle(
                            "Daily vocabulary transfer",
                            isOn: Binding(
                                get: { model.study.wanikaniTransferBridgeEnabled },
                                set: { enabled in
                                    Task {
                                        await model.study
                                            .setWaniKaniTransferBridgeEnabled(enabled)
                                    }
                                }
                            )
                        )
                        .disabled(model.study.isWaniKaniWorking)
                        .accessibilityIdentifier("WaniKaniTransferBridgeToggle")
                        .accessibilityHint(
                            "Automatically imports recently passed WaniKani vocabulary into ConvoLab practice"
                        )
                        Text(
                            "Imports up to two recently passed vocabulary items each day as four contextual listening, recognition, and cloze cards. Related cards unlock over time."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        if shouldShowWaniKaniTransferStatus {
                            LabeledContent(
                                "Vocabulary imported",
                                value: model.study.wanikaniImportedVocabularyCount.formatted()
                            )
                            if model.study.wanikaniPendingVocabularyCount > 0 {
                                LabeledContent(
                                    "Imports in progress",
                                    value: model.study.wanikaniPendingVocabularyCount.formatted()
                                )
                            }
                            if model.study.wanikaniFailedVocabularyCount > 0 {
                                LabeledContent("Imports needing retry") {
                                    Text(
                                        model.study.wanikaniFailedVocabularyCount.formatted()
                                    )
                                    .foregroundStyle(.red)
                                }
                                Text("Failed imports retry automatically during a future WaniKani sync.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if let lastImportedAt = model.study.wanikaniLastImportedAt {
                                LabeledContent(
                                    "Last vocabulary import",
                                    value: lastImportedAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened
                                    )
                                )
                            }
                        }
                        Button("Sync WaniKani") {
                            Task { await model.study.syncWaniKani() }
                        }
                        .disabled(model.study.isWaniKaniWorking)
                        Button("Disconnect WaniKani", role: .destructive) {
                            confirmingWaniKaniDisconnect = true
                        }
                        .disabled(model.study.isWaniKaniWorking)
                    } else {
                        SecureField("WaniKani API token", text: $wanikaniAPIToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                        Button("Connect and Sync") {
                            let token = wanikaniAPIToken
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await model.study.connectWaniKani(apiToken: token)
                                if model.study.wanikaniConnected {
                                    wanikaniAPIToken = ""
                                }
                            }
                        }
                        .disabled(
                            wanikaniAPIToken
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                                || model.study.isWaniKaniWorking
                        )
                    }

                    if model.study.isWaniKaniWorking {
                        ProgressView("Updating WaniKani…")
                    }
                    if let error = model.study.wanikaniErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Text(
                        "Furigana stays visible unless every kanji in a word is in your synced known-kanji set. The API token is sent to learning-os and is never saved on this device."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Button("Sync Now") {
                        Task {
                            await model.synchronize()
                        }
                    }
                    Button("Sign Out", role: .destructive) {
                        Task { await model.logout() }
                    }
                    Button("Delete Account", role: .destructive) {
                        showingAccountDeletion = true
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                async let studySettings: Void = model.study.refreshStudySettings()
                async let calendar: Void = model.studyTime.loadGoogleCalendarConnection()
                _ = await (studySettings, calendar)
                if let settings = model.study.studySettings {
                    newCardsPerDay = settings.newCardsPerDay
                    lessonBatchSize = settings.lessonBatchSize
                    reviewTimeBudgetMinutes = settings.reviewTimeBudgetMinutes
                    laneWeights = settings.newCardLaneWeights
                }
            }
            .confirmationDialog(
                "Disconnect Google Calendar?",
                isPresented: $confirmingCalendarDisconnect,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    Task { await model.studyTime.disconnectGoogleCalendar() }
                }
                .disabled(model.studyTime.googleCalendarIsLoading)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Calendar study time already imported into your analytics will remain.")
            }
            .confirmationDialog(
                "Disconnect WaniKani?",
                isPresented: $confirmingWaniKaniDisconnect,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    Task { await model.study.disconnectWaniKani() }
                }
                .disabled(model.study.isWaniKaniWorking)
            } message: {
                Text("Previously learned kanji remain known in learning-os.")
            }
            .confirmationDialog(
                "Remove downloaded media?",
                isPresented: $confirmingClearDownloads,
                titleVisibility: .visible
            ) {
                Button("Remove Downloads", role: .destructive) {
                    try? model.clearDownloadedMedia()
                }
            } message: {
                Text("Cards remain available. Audio and images will download again when needed.")
            }
            .sheet(isPresented: $showingProfileEditor) {
                ProfileEditorView(auth: model.auth, user: user)
            }
            .sheet(isPresented: $showingPasswordEditor) {
                PasswordEditorView(auth: model.auth)
            }
            .sheet(isPresented: $showingAccountDeletion) {
                AccountDeletionView(model: model)
            }
            .sheet(item: $calendarSettingsModel) { calendarModel in
                GoogleCalendarSettingsView(model: calendarModel)
            }
        }
        .sheet(isPresented: $showingFailedStudyChanges) {
            FailedStudyChangesView(store: model.study)
        }
    }

    private var offlineStudyWindow: String {
        guard let days = model.study.offlineReserveDays else { return "Not synced" }
        guard model.study.offlineReserveIsCurrent else { return "Expired" }
        return "\(days) \(days == 1 ? "day" : "days")"
    }

    private func laneWeightBinding(
        _ keyPath: WritableKeyPath<StudyNewCardLaneWeights, Int>
    ) -> Binding<Int> {
        Binding(
            get: { laneWeights?[keyPath: keyPath] ?? 0 },
            set: { value in
                guard var updated = laneWeights else { return }
                updated[keyPath: keyPath] = value
                laneWeights = updated
                studySettingsSaved = false
            }
        )
    }

    @ViewBuilder
    private var googleCalendarSection: some View {
        Section("Google Calendar") {
            if model.studyTime.googleCalendarIsLoading,
               model.studyTime.googleCalendarStatus == nil
            {
                HStack {
                    ProgressView()
                    Text("Checking connection…")
                }
            } else if model.studyTime.googleCalendarStatus?.connected == true {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if let email = model.studyTime.googleCalendarStatus?.accountEmail {
                    LabeledContent("Account", value: email)
                }
                if let lastSync = model.studyTime.googleCalendarStatus?.lastSyncedAt {
                    LabeledContent("Last sync") {
                        Text(
                            lastSync,
                            format: .dateTime.month(.abbreviated).day().hour().minute()
                        )
                    }
                } else {
                    LabeledContent("Last sync", value: "Waiting for first sync")
                }
                if model.studyTime.googleCalendarIsWorking {
                    HStack {
                        ProgressView()
                        Text("Disconnecting…")
                    }
                } else {
                    Button {
                        calendarSettingsModel = model.studyTime.makeGoogleCalendarSettingsModel()
                    } label: {
                        Label("Calendar Settings", systemImage: "calendar")
                            .frame(minHeight: 44)
                    }
                    .disabled(model.studyTime.googleCalendarIsLoading)

                    Button("Disconnect", role: .destructive) {
                        confirmingCalendarDisconnect = true
                    }
                    .frame(minHeight: 44)
                    .disabled(model.studyTime.googleCalendarIsLoading)
                }
            } else {
                Text("Connect your account to include calendar lessons in study analytics.")
                    .foregroundStyle(.secondary)
                Button {
                    Task { await model.studyTime.connectGoogleCalendar() }
                } label: {
                    if model.studyTime.googleCalendarIsWorking {
                        HStack {
                            ProgressView()
                            Text("Connecting…")
                        }
                    } else {
                        Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                    }
                }
                .disabled(
                    model.studyTime.googleCalendarIsLoading
                        || model.studyTime.googleCalendarIsWorking
                )
            }

            if let message = model.studyTime.googleCalendarErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                if model.studyTime.googleCalendarStatus == nil {
                    Button("Retry") {
                        Task { await model.studyTime.loadGoogleCalendarConnection() }
                    }
                    .disabled(
                        model.studyTime.googleCalendarIsLoading
                            || model.studyTime.googleCalendarIsWorking
                    )
                }
            }
        }
    }

    private var shouldShowWaniKaniTransferStatus: Bool {
        model.study.wanikaniTransferBridgeEnabled
            || model.study.wanikaniImportedVocabularyCount > 0
            || model.study.wanikaniPendingVocabularyCount > 0
            || model.study.wanikaniFailedVocabularyCount > 0
            || model.study.wanikaniLastImportedAt != nil
    }
}

private struct ProfileEditorView: View {
    let auth: AuthStore
    @State private var name: String
    @State private var email: String
    @Environment(\.dismiss) private var dismiss

    init(auth: AuthStore, user: CurrentUser) {
        self.auth = auth
        _name = State(initialValue: user.name)
        _email = State(initialValue: user.email)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .textContentType(.name)
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                accountError(auth)
            }
            .navigationTitle("Edit Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await auth.updateProfile(name: name, email: email) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(name.isEmpty || email.isEmpty || auth.isWorking)
                }
            }
        }
    }
}

private struct PasswordEditorView: View {
    let auth: AuthStore
    @State private var currentPassword = ""
    @State private var password = ""
    @State private var confirmation = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                SecureField("Current password", text: $currentPassword)
                SecureField("New password", text: $password)
                    .textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmation)
                    .textContentType(.newPassword)
                accountError(auth)
            }
            .navigationTitle("Change Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") {
                        Task {
                            if await auth.updatePassword(
                                currentPassword: currentPassword,
                                password: password,
                                passwordConfirmation: confirmation
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        currentPassword.isEmpty
                            || password.isEmpty
                            || password != confirmation
                            || auth.isWorking
                    )
                }
            }
        }
    }
}

private struct AccountDeletionView: View {
    let model: AppModel
    @State private var currentPassword = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This permanently deletes your Learning OS account and study data.")
                        .foregroundStyle(.red)
                    SecureField("Current password", text: $currentPassword)
                    accountError(model.auth)
                }
                Section {
                    Button("Permanently Delete Account", role: .destructive) {
                        Task {
                            if await model.deleteAccount(currentPassword: currentPassword) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(currentPassword.isEmpty || model.auth.isWorking)
                }
            }
            .navigationTitle("Delete Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

@ViewBuilder
private func accountError(_ auth: AuthStore) -> some View {
    if let error = auth.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
    }
}

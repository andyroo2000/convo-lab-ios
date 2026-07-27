import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let user: CurrentUser

    @State private var wanikaniAPIToken = ""
    @State private var confirmingWaniKaniDisconnect = false
    @State private var confirmingClearDownloads = false
    @State private var showingProfileEditor = false
    @State private var showingPasswordEditor = false
    @State private var showingAccountDeletion = false
    @State private var newCardsPerDay: Int
    @State private var lessonBatchSize: Int
    @State private var studySettingsSaved = false

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
                    LabeledContent("Study window", value: "5 days")
                    Button("Remove Downloaded Media", role: .destructive) {
                        confirmingClearDownloads = true
                    }
                    LabeledContent(
                        "Changes needing attention",
                        value: model.study.quarantinedMutationCount.formatted()
                    )
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

                    Button(model.study.isUpdatingStudySettings ? "Saving…" : "Save Study Settings") {
                        Task {
                            studySettingsSaved = await model.study
                                .updateStudySettings(
                                    newCardsPerDay: newCardsPerDay,
                                    lessonBatchSize: lessonBatchSize
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
                        "The daily limit is your allowance. Cards per lesson controls the preview-and-quiz batch size."
                    )
                }

                Section("Integrations") {
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
                        ProgressView("Updating WaniKani knowledge…")
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
                await model.study.refreshStudySettings()
                if let settings = model.study.studySettings {
                    newCardsPerDay = settings.newCardsPerDay
                    lessonBatchSize = settings.lessonBatchSize
                }
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
        }
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

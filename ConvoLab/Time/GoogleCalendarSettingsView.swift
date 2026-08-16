import SwiftUI

@MainActor
@Observable
final class GoogleCalendarSettingsModel: Identifiable {
    enum ContentState: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed(String)
    }

    let id = UUID()
    private let service: any GoogleCalendarConnectionServing
    private let didSave: @MainActor () async -> Void
    private let didSync: @MainActor () async -> Void
    private let pollDelay: @Sendable () async throws -> Void
    private var settings: GoogleCalendarSettings?
    private var requestGeneration = 0
    private var completionPending = false
    private var pollingExhausted = false
    private(set) var state: ContentState = .idle
    private(set) var calendars: [GoogleCalendar] = []
    private(set) var selectedCalendarIDs: Set<String>
    private(set) var titleMatchTerms: [String]
    private(set) var automaticTrackingEnabled: Bool
    private(set) var isTruncated = false
    private(set) var isSaving = false
    private(set) var saveErrorMessage: String?
    private(set) var connectionStatus: GoogleCalendarConnectionStatus?
    private(set) var isStartingSync = false
    private(set) var syncErrorMessage: String?
    private(set) var pollingGeneration = 0

    init(
        service: any GoogleCalendarConnectionServing,
        initialSettings: GoogleCalendarSettings?,
        didSave: @escaping @MainActor () async -> Void = {},
        didSync: @escaping @MainActor () async -> Void = {},
        pollDelay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(2))
        }
    ) {
        self.service = service
        self.settings = initialSettings
        self.selectedCalendarIDs = Set(initialSettings?.calendarIds ?? [])
        self.titleMatchTerms = initialSettings?.titleMatchTerms ?? []
        self.automaticTrackingEnabled = initialSettings?.syncEnabled ?? false
        self.didSave = didSave
        self.didSync = didSync
        self.pollDelay = pollDelay
    }

    var syncIsActive: Bool { connectionStatus?.sync?.status.isActive == true }
    var editsLocked: Bool { isSaving || isStartingSync || syncIsActive }
    var blocksDismissal: Bool { isSaving || isStartingSync }
    var shouldPoll: Bool { syncIsActive && !pollingExhausted }
    var requiresReconnect: Bool { connectionStatus?.sync?.errorCode == "reconnect_required" }

    var hasUnsavedChanges: Bool {
        guard let settings else { return true }
        do {
            return try currentCalendarIDs()
                != GoogleCalendarSettingsDraft.canonicalizedCalendarIDs(settings.calendarIds)
                || GoogleCalendarSettingsDraft.canonicalizedTerms(titleMatchTerms)
                != GoogleCalendarSettingsDraft.canonicalizedTerms(settings.titleMatchTerms)
                || automaticTrackingEnabled != settings.syncEnabled
        } catch {
            return true
        }
    }

    var canSync: Bool {
        state == .loaded && settings != nil && !hasUnsavedChanges
            && !isSaving && !isStartingSync && !shouldPoll && !requiresReconnect
    }

    var syncActionTitle: String {
        if requiresReconnect { return "Reconnect Required" }
        if syncIsActive { return "Check Sync Status" }
        if connectionStatus?.sync?.status == .failed || syncErrorMessage != nil { return "Try Again" }
        return "Sync Now"
    }

    var syncHelpText: String {
        if settings == nil { return "Save calendar and title settings before syncing." }
        if hasUnsavedChanges { return "Save changes before syncing. Manual sync uses your saved settings." }
        return "Manual sync uses your saved settings and works even when automatic tracking is off."
    }

    var canSave: Bool {
        canPreview
    }

    var canPreview: Bool {
        state == .loaded
            && calendarValidationMessage == nil
            && titleTermsValidationMessage == nil
            && !editsLocked
    }

    var calendarValidationMessage: String? {
        guard !selectedCalendarIDs.isEmpty else {
            return "Select at least one calendar to preview or save."
        }
        do {
            _ = try currentCalendarIDs()
            return nil
        } catch {
            return Self.safeMessage(for: error)
        }
    }

    var titleTermsValidationMessage: String? {
        do {
            _ = try GoogleCalendarSettingsDraft.canonicalizedTerms(titleMatchTerms)
            return nil
        } catch {
            return Self.safeMessage(for: error)
        }
    }

    var unavailableSelectedCount: Int {
        unavailableSelectedCalendarIDs.count
    }

    var unavailableSelectedCalendarIDs: [String] {
        let availableIDs = Set(calendars.map(\.id))
        return (settings?.calendarIds ?? []).filter {
            selectedCalendarIDs.contains($0) && !availableIDs.contains($0)
        }
    }

    func load() async {
        guard state != .loading, !editsLocked else { return }
        requestGeneration += 1
        let generation = requestGeneration
        state = .loading
        saveErrorMessage = nil
        syncErrorMessage = nil
        do {
            let status = try Self.normalizedStatus(try await service.status())
            guard !Task.isCancelled, requestGeneration == generation else { return }
            let response = try await service.calendars()
            guard !Task.isCancelled, requestGeneration == generation else { return }
            calendars = response.calendars
            isTruncated = response.truncated
            settings = status.settings
            selectedCalendarIDs = Set(status.settings?.calendarIds ?? [])
            titleMatchTerms = status.settings?.titleMatchTerms ?? []
            automaticTrackingEnabled = status.settings?.syncEnabled ?? false
            connectionStatus = status
            if status.sync?.status.isActive == true {
                completionPending = true
                pollingExhausted = false
                pollingGeneration += 1
            } else if status.sync?.status == .failed {
                syncErrorMessage = Self.syncFailureMessage(status.sync)
            }
            state = calendars.isEmpty ? .empty : .loaded
        } catch {
            guard !Task.isCancelled, requestGeneration == generation else { return }
            state = .failed(Self.safeMessage(for: error))
        }
    }

    func toggleCalendar(id: String) {
        guard !editsLocked, state == .loaded, calendars.contains(where: { $0.id == id }) else { return }
        saveErrorMessage = nil
        if selectedCalendarIDs.contains(id) {
            selectedCalendarIDs.remove(id)
        } else {
            guard selectedCalendarIDs.count < 25 else {
                saveErrorMessage = GoogleCalendarSettingsValidationError.calendarCount.localizedDescription
                return
            }
            selectedCalendarIDs.insert(id)
        }
    }

    func removeUnavailableCalendar(id: String) {
        guard !editsLocked, unavailableSelectedCalendarIDs.contains(id) else { return }
        selectedCalendarIDs.remove(id)
        saveErrorMessage = nil
    }

    @discardableResult
    func addTitleMatchTerm(_ input: String) -> Bool {
        guard !editsLocked else { return false }
        saveErrorMessage = nil
        do {
            let candidate = try GoogleCalendarSettingsDraft.canonicalizedTerms([input])[0]
            let candidateKey = GoogleCalendarSettingsDraft.termComparisonKey(candidate)
            guard !titleMatchTerms.contains(where: {
                GoogleCalendarSettingsDraft.termComparisonKey($0) == candidateKey
            }) else {
                saveErrorMessage = "That title-match term is already included."
                return false
            }
            guard titleMatchTerms.count < 50 else {
                throw GoogleCalendarSettingsValidationError.termCount
            }
            titleMatchTerms.append(candidate)
            return true
        } catch {
            saveErrorMessage = Self.safeMessage(for: error)
            return false
        }
    }

    func removeTitleMatchTerm(at index: Int) {
        guard !editsLocked, titleMatchTerms.indices.contains(index) else { return }
        titleMatchTerms.remove(at: index)
        saveErrorMessage = nil
    }

    func setAutomaticTrackingEnabled(_ enabled: Bool) {
        guard state == .loaded, !editsLocked else { return }
        automaticTrackingEnabled = enabled
        saveErrorMessage = nil
    }

    func makePreviewModel() -> GoogleCalendarPreviewModel? {
        guard canPreview else { return nil }
        do {
            return GoogleCalendarPreviewModel(
                service: service,
                request: .init(
                    calendarIds: try currentCalendarIDs(),
                    titleMatchTerms: try GoogleCalendarSettingsDraft.canonicalizedTerms(titleMatchTerms)
                )
            )
        } catch {
            saveErrorMessage = Self.safeMessage(for: error)
            return nil
        }
    }

    private func currentCalendarIDs() throws -> [String] {
        let existing = (settings?.calendarIds ?? []).filter(selectedCalendarIDs.contains)
        let seen = Set(existing)
        let added = calendars.map(\.id).filter {
            selectedCalendarIDs.contains($0) && !seen.contains($0)
        }
        return try GoogleCalendarSettingsDraft.canonicalizedCalendarIDs(existing + added)
    }

    @discardableResult
    func save() async -> Bool {
        guard !selectedCalendarIDs.isEmpty else {
            saveErrorMessage = "Select at least one calendar to save."
            return false
        }
        guard !titleMatchTerms.isEmpty else {
            saveErrorMessage = "Add at least one title-match term to save."
            return false
        }
        guard state == .loaded, !editsLocked else { return false }
        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }

        do {
            let freshStatus = try await service.status()
            guard freshStatus.connected else { throw GoogleCalendarConnectionError.notConnected }
            let initialSettings = settings
            guard initialSettings == nil || freshStatus.settings != nil else {
                throw GoogleCalendarConnectionError.invalidSettings
            }
            let freshSettings = freshStatus.settings
            let baseSyncEnabled = initialSettings?.syncEnabled ?? false
            let mergedSyncEnabled = automaticTrackingEnabled != baseSyncEnabled
                ? automaticTrackingEnabled
                : freshSettings?.syncEnabled ?? false
            let initialIDs = Set(initialSettings?.calendarIds ?? [])
            let removedIDs = initialIDs.subtracting(selectedCalendarIDs)
            let addedIDs = selectedCalendarIDs.subtracting(initialIDs)
            var mergedIDs = (freshSettings?.calendarIds ?? []).filter { !removedIDs.contains($0) }
            var seenIDs = Set(mergedIDs)
            for id in calendars.map(\.id)
                where addedIDs.contains(id) && seenIDs.insert(id).inserted
            {
                mergedIDs.append(id)
            }
            let calendarIds = try GoogleCalendarSettingsDraft.canonicalizedCalendarIDs(mergedIDs)

            let initialTerms = initialSettings?.titleMatchTerms ?? []
            let localTerms = try GoogleCalendarSettingsDraft.canonicalizedTerms(titleMatchTerms)
            let initialKeys = Set(initialTerms.map(GoogleCalendarSettingsDraft.termComparisonKey))
            let localKeys = Set(localTerms.map(GoogleCalendarSettingsDraft.termComparisonKey))
            let removedTermKeys = initialKeys.subtracting(localKeys)
            let addedTermKeys = localKeys.subtracting(initialKeys)
            var mergedTerms = (freshSettings?.titleMatchTerms ?? []).filter {
                !removedTermKeys.contains(GoogleCalendarSettingsDraft.termComparisonKey($0))
            }
            var seenTermKeys = Set(mergedTerms.map(GoogleCalendarSettingsDraft.termComparisonKey))
            for term in localTerms {
                let key = GoogleCalendarSettingsDraft.termComparisonKey(term)
                if addedTermKeys.contains(key), seenTermKeys.insert(key).inserted {
                    mergedTerms.append(term)
                }
            }
            let request = GoogleCalendarSettings(
                calendarIds: calendarIds,
                titleMatchTerms: try GoogleCalendarSettingsDraft.canonicalizedTerms(mergedTerms),
                syncEnabled: mergedSyncEnabled
            )
            let savedSettings = try await service.updateSettings(request)
            self.settings = savedSettings
            automaticTrackingEnabled = savedSettings.syncEnabled
            await didSave()
            return true
        } catch {
            saveErrorMessage = Self.safeMessage(for: error)
            return false
        }
    }

    func startManualSync() async {
        guard canSync else { return }
        if syncIsActive {
            await checkActiveSyncStatus()
            return
        }
        requestGeneration += 1
        let generation = requestGeneration
        isStartingSync = true
        syncErrorMessage = nil
        pollingExhausted = false
        completionPending = true
        defer {
            if requestGeneration == generation { isStartingSync = false }
        }
        do {
            let status = try await service.sync()
            guard !Task.isCancelled, requestGeneration == generation else { return }
            guard status.connected else { throw GoogleCalendarConnectionError.notConnected }
            guard status.sync != nil else { throw GoogleCalendarConnectionError.requestFailed }
            connectionStatus = status
            if status.sync?.status.isActive == true { pollingGeneration += 1 }
            await finishSyncIfNeeded(status)
        } catch {
            guard !Task.isCancelled, requestGeneration == generation else { return }
            completionPending = false
            syncErrorMessage = Self.safeMessage(for: error)
        }
    }

    private func checkActiveSyncStatus() async {
        requestGeneration += 1
        let generation = requestGeneration
        isStartingSync = true
        syncErrorMessage = nil
        defer {
            if requestGeneration == generation { isStartingSync = false }
        }
        do {
            let status = try Self.normalizedStatus(try await service.status())
            guard !Task.isCancelled, requestGeneration == generation else { return }
            connectionStatus = status
            pollingExhausted = false
            if status.sync?.status.isActive == true { pollingGeneration += 1 }
            await finishSyncIfNeeded(status)
        } catch {
            guard !Task.isCancelled, requestGeneration == generation else { return }
            pollingExhausted = true
            syncErrorMessage = Self.safeMessage(for: error)
        }
    }

    func pollUntilSettled(maxAttempts: Int = 30) async {
        guard shouldPoll else { return }
        let generation = requestGeneration
        for _ in 0..<maxAttempts {
            do { try await pollDelay() } catch { return }
            guard !Task.isCancelled, requestGeneration == generation, shouldPoll else { return }
            do {
                let status = try Self.normalizedStatus(try await service.status())
                guard !Task.isCancelled, requestGeneration == generation else { return }
                connectionStatus = status
                if !syncIsActive {
                    await finishSyncIfNeeded(status)
                    return
                }
            } catch {
                guard !Task.isCancelled, requestGeneration == generation else { return }
                pollingExhausted = true
                syncErrorMessage = Self.safeMessage(for: error)
                return
            }
        }
        guard requestGeneration == generation, syncIsActive else { return }
        pollingExhausted = true
        syncErrorMessage = "Sync is still running. Check its status again in a moment."
    }

    private func finishSyncIfNeeded(_ status: GoogleCalendarConnectionStatus) async {
        switch status.sync?.status {
        case .succeeded:
            syncErrorMessage = nil
            guard completionPending else { return }
            completionPending = false
            await didSync()
        case .failed:
            completionPending = false
            syncErrorMessage = Self.syncFailureMessage(status.sync)
        case .idle:
            completionPending = false
        case .queued, .running, .none:
            break
        }
    }

    private static func syncFailureMessage(_ sync: GoogleCalendarSyncState?) -> String {
        if sync?.errorCode == "reconnect_required" {
            return "Reconnect Google Calendar before syncing again. Return to Study Time, disconnect, then connect your account again."
        }
        return "Google Calendar sync didn’t finish. Try again."
    }

    private static func normalizedStatus(
        _ status: GoogleCalendarConnectionStatus
    ) throws -> GoogleCalendarConnectionStatus {
        guard status.connected else { throw GoogleCalendarConnectionError.notConnected }
        guard status.sync == nil else { return status }
        return GoogleCalendarConnectionStatus(
            connected: true,
            accountEmail: status.accountEmail,
            scopes: status.scopes,
            settings: status.settings,
            connectedAt: status.connectedAt,
            lastSyncedAt: status.lastSyncedAt,
            sync: GoogleCalendarSyncState(status: .idle, errorCode: nil, statusAt: nil)
        )
    }

    private static func safeMessage(for error: Error) -> String {
        if let validation = error as? GoogleCalendarSettingsValidationError {
            return validation.localizedDescription
        }
        return googleCalendarFriendlyMessage(for: error)
            ?? "Something went wrong with Google Calendar. Please try again."
    }
}

struct GoogleCalendarSettingsView: View {
    let model: GoogleCalendarSettingsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var titleTermDraft = ""
    @State private var previewModel: GoogleCalendarPreviewModel?

    var body: some View {
        NavigationStack {
            List {
                content
            }
            .navigationTitle("Calendar Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.blocksDismissal)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await model.save() { dismiss() }
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
            .interactiveDismissDisabled(model.blocksDismissal)
            .task { await model.load() }
            .task(id: CalendarSyncPollTaskID(
                generation: model.pollingGeneration,
                appIsActive: scenePhase == .active
            )) {
                guard scenePhase == .active else { return }
                await model.pollUntilSettled()
            }
            .sheet(item: $previewModel) { GoogleCalendarPreviewView(model: $0) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading calendars…")
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .loaded:
            Section {
                ForEach(model.calendars) { calendar in
                    calendarButton(calendar)
                }
            } header: {
                Text("Calendars")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose calendars that contain your conversation lessons.")
                    if model.unavailableSelectedCount > 0 {
                        Text("Previously selected unavailable calendars will stay selected.")
                    }
                    if model.isTruncated {
                        Text("Only the first available calendars are shown.")
                    }
                    if let message = model.calendarValidationMessage {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            if !model.unavailableSelectedCalendarIDs.isEmpty {
                Section("Unavailable Calendars") {
                    ForEach(model.unavailableSelectedCalendarIDs, id: \.self) { id in
                        Button(role: .destructive) {
                            model.removeUnavailableCalendar(id: id)
                        } label: {
                            HStack(spacing: 12) {
                                Text(id)
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Label("Remove", systemImage: "trash")
                                    .labelStyle(.iconOnly)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Remove unavailable calendar \(id)")
                        .disabled(model.editsLocked)
                    }
                }
            }
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("e.g. iTalki or lesson", text: $titleTermDraft)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit(addTitleTerm)
                        .accessibilityLabel("New title-match term")
                        .disabled(model.editsLocked)
                    Button("Add", action: addTitleTerm)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(titleTermDraft.isEmpty || model.editsLocked)
                }
                ForEach(Array(model.titleMatchTerms.enumerated()), id: \.offset) { index, term in
                    Button(role: .destructive) {
                        model.removeTitleMatchTerm(at: index)
                    } label: {
                        HStack(spacing: 12) {
                            Text(term)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "minus.circle.fill")
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Remove title-match term \(term)")
                    .disabled(model.editsLocked)
                }
            } header: {
                Text("Lesson Title Terms")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add words found in conversation lesson titles, such as iTalki or lesson. No examples are added automatically.")
                    Text("1–50 terms, up to 100 characters each.")
                    if let message = model.titleTermsValidationMessage {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section {
                Button {
                    previewModel = model.makePreviewModel()
                } label: {
                    Label("Preview matching events", systemImage: "calendar.badge.clock")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .disabled(!model.canPreview)
                .accessibilityHint("Shows matching completed events from the server’s recent preview window without importing them")
            } footer: {
                Text("Preview uses the selections above. It does not import or sync anything.")
            }
            Section {
                Toggle(
                    "Add matching lessons automatically",
                    isOn: Binding(
                        get: { model.automaticTrackingEnabled },
                        set: { model.setAutomaticTrackingEnabled($0) }
                    )
                )
                .disabled(model.editsLocked)
                .accessibilityIdentifier("GoogleCalendarAutomaticTrackingToggle")
                .accessibilityHint(
                    "When on, completed matching events are added as Conversation study time during automatic calendar sync"
                )
            } header: {
                Text("Automatic Tracking")
            } footer: {
                Text("When on, completed events matching the calendars and title terms above will be added as Conversation time during automatic calendar sync. Saving this setting does not run a sync.")
            }
            syncSection
            if let message = model.saveErrorMessage {
                errorLabel(message)
            }
        case .empty:
            unavailableContent(
                title: "No readable calendars",
                description: "Google did not return any calendars you can read."
            )
            Button("Refresh Calendars") { Task { await model.load() } }
                .frame(minHeight: 44)
        case let .failed(message):
            errorLabel(message)
            Button("Try Again") { Task { await model.load() } }
                .frame(minHeight: 44)
        }
    }

    private func addTitleTerm() {
        if model.addTitleMatchTerm(titleTermDraft) {
            titleTermDraft = ""
        }
    }

    private func calendarButton(_ calendar: GoogleCalendar) -> some View {
        let selected = model.selectedCalendarIDs.contains(calendar.id)
        return Button {
            model.toggleCalendar(id: calendar.id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(calendar.name)
                        .foregroundStyle(.primary)
                    if calendar.primary {
                        Text("Primary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? ConvoLabTheme.navy : .secondary)
                    .font(.title3)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendar.primary ? "\(calendar.name), primary calendar" : calendar.name)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Double-tap to \(selected ? "deselect" : "select") this calendar")
        .disabled(model.editsLocked)
    }

    private var syncSection: some View {
        Section {
            LabeledContent("Last synced") {
                if let date = model.connectionStatus?.lastSyncedAt {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                } else {
                    Text("Never")
                }
            }
            if model.isStartingSync {
                syncProgress(model.syncIsActive ? "Checking sync status…" : "Starting sync…")
            } else if let phase = model.connectionStatus?.sync?.status {
                switch phase {
                case .queued:
                    syncProgress("Sync queued…")
                case .running:
                    syncProgress("Syncing matching events…")
                case .succeeded:
                    Label("Sync complete", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Label("Sync needs attention", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                case .idle:
                    EmptyView()
                }
            }
            Button {
                Task { await model.startManualSync() }
            } label: {
                Label(model.syncActionTitle, systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(!model.canSync)
            .accessibilityHint("Adds completed events matching your saved settings as Conversation study time")
            if let message = model.syncErrorMessage {
                errorLabel(message)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(model.syncHelpText)
        }
    }

    private func syncProgress(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(message)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .accessibilityLabel("Error: \(message)")
    }

    private func unavailableContent(title: String, description: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: "calendar.badge.exclamationmark",
            description: Text(description)
        )
    }
}

private struct CalendarSyncPollTaskID: Hashable {
    let generation: Int
    let appIsActive: Bool
}

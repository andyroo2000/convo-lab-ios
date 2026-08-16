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
    private var settings: GoogleCalendarSettings?
    private(set) var state: ContentState = .idle
    private(set) var calendars: [GoogleCalendar] = []
    private(set) var selectedCalendarIDs: Set<String>
    private(set) var titleMatchTerms: [String]
    private(set) var isTruncated = false
    private(set) var isSaving = false
    private(set) var saveErrorMessage: String?

    init(
        service: any GoogleCalendarConnectionServing,
        initialSettings: GoogleCalendarSettings?,
        didSave: @escaping @MainActor () async -> Void = {}
    ) {
        self.service = service
        self.settings = initialSettings
        self.selectedCalendarIDs = Set(initialSettings?.calendarIds ?? [])
        self.titleMatchTerms = initialSettings?.titleMatchTerms ?? []
        self.didSave = didSave
    }

    var canSave: Bool {
        canPreview
    }

    var canPreview: Bool {
        state == .loaded
            && !selectedCalendarIDs.isEmpty
            && titleTermsValidationMessage == nil
            && !isSaving
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
        guard state != .loading, !isSaving else { return }
        state = .loading
        saveErrorMessage = nil
        do {
            let status = try await service.status()
            guard status.connected else { throw GoogleCalendarConnectionError.notConnected }
            let response = try await service.calendars()
            calendars = response.calendars
            isTruncated = response.truncated
            settings = status.settings
            selectedCalendarIDs = Set(status.settings?.calendarIds ?? [])
            titleMatchTerms = status.settings?.titleMatchTerms ?? []
            state = calendars.isEmpty ? .empty : .loaded
        } catch {
            state = .failed(Self.safeMessage(for: error))
        }
    }

    func toggleCalendar(id: String) {
        guard !isSaving, state == .loaded, calendars.contains(where: { $0.id == id }) else { return }
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
        guard !isSaving, unavailableSelectedCalendarIDs.contains(id) else { return }
        selectedCalendarIDs.remove(id)
        saveErrorMessage = nil
    }

    @discardableResult
    func addTitleMatchTerm(_ input: String) -> Bool {
        guard !isSaving else { return false }
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
        guard !isSaving, titleMatchTerms.indices.contains(index) else { return }
        titleMatchTerms.remove(at: index)
        saveErrorMessage = nil
    }

    func makePreviewModel() -> GoogleCalendarPreviewModel? {
        guard canPreview else { return nil }
        let existing = (settings?.calendarIds ?? []).filter(selectedCalendarIDs.contains)
        let seen = Set(existing)
        let added = calendars.map(\.id).filter {
            selectedCalendarIDs.contains($0) && !seen.contains($0)
        }
        guard let calendarIds = try? GoogleCalendarSettingsDraft.canonicalizedCalendarIDs(existing + added),
              let terms = try? GoogleCalendarSettingsDraft.canonicalizedTerms(titleMatchTerms)
        else { return nil }
        return GoogleCalendarPreviewModel(
            service: service,
            request: .init(calendarIds: calendarIds, titleMatchTerms: terms)
        )
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
        guard state == .loaded, !isSaving else { return false }
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
                syncEnabled: freshSettings?.syncEnabled ?? false
            )
            self.settings = try await service.updateSettings(request)
            await didSave()
            return true
        } catch {
            saveErrorMessage = Self.safeMessage(for: error)
            return false
        }
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
                        .disabled(model.isSaving)
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
            .interactiveDismissDisabled(model.isSaving)
            .task { await model.load() }
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
                    if model.selectedCalendarIDs.isEmpty {
                        Text("Select at least one calendar to save.")
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
                        .disabled(model.isSaving)
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
                        .disabled(model.isSaving)
                    Button("Add", action: addTitleTerm)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(titleTermDraft.isEmpty || model.isSaving)
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
                    .disabled(model.isSaving)
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
                .accessibilityHint("Shows matching completed events from the last 31 days without importing them")
            } footer: {
                Text("Preview uses the selections above. It does not import or sync anything.")
            }
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
        .disabled(model.isSaving)
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

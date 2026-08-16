import SwiftUI

@MainActor
@Observable
final class GoogleCalendarSettingsModel: Identifiable {
    enum ContentState: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case unconfigured
        case failed(String)
    }

    let id = UUID()
    private let service: any GoogleCalendarConnectionServing
    private let didSave: @MainActor () async -> Void
    private var settings: GoogleCalendarSettings?
    private(set) var state: ContentState = .idle
    private(set) var calendars: [GoogleCalendar] = []
    private(set) var selectedCalendarIDs: Set<String>
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
        self.didSave = didSave
    }

    var canSave: Bool {
        state == .loaded && !selectedCalendarIDs.isEmpty && !isSaving
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
            guard let currentSettings = status.settings else {
                settings = nil
                selectedCalendarIDs = []
                state = .unconfigured
                return
            }
            settings = currentSettings
            selectedCalendarIDs = Set(currentSettings.calendarIds)
            state = calendars.isEmpty ? .empty : .loaded
        } catch {
            state = .failed(Self.safeMessage(for: error))
        }
    }

    func toggleCalendar(id: String) {
        guard state == .loaded, calendars.contains(where: { $0.id == id }) else { return }
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
        guard unavailableSelectedCalendarIDs.contains(id) else { return }
        selectedCalendarIDs.remove(id)
        saveErrorMessage = nil
    }

    @discardableResult
    func save() async -> Bool {
        guard !selectedCalendarIDs.isEmpty else {
            saveErrorMessage = "Select at least one calendar to save."
            return false
        }
        guard state == .loaded, !isSaving, let settings else { return false }
        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }

        let existing = settings.calendarIds.filter(selectedCalendarIDs.contains)
        let existingIDs = Set(existing)
        let added = calendars.map(\.id).filter {
            selectedCalendarIDs.contains($0) && !existingIDs.contains($0)
        }
        do {
            let calendarIds = try GoogleCalendarSettingsDraft.canonicalizedCalendarIDs(existing + added)
            let freshStatus = try await service.status()
            guard freshStatus.connected else { throw GoogleCalendarConnectionError.notConnected }
            guard let freshSettings = freshStatus.settings else {
                throw GoogleCalendarConnectionError.invalidSettings
            }
            let request = GoogleCalendarSettings(
                calendarIds: calendarIds,
                titleMatchTerms: freshSettings.titleMatchTerms,
                syncEnabled: freshSettings.syncEnabled
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
                    }
                }
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
        case .unconfigured:
            unavailableContent(
                title: "Setup not complete",
                description: "Calendar matching terms must be configured before calendars can be selected."
            )
        case let .failed(message):
            errorLabel(message)
            Button("Try Again") { Task { await model.load() } }
                .frame(minHeight: 44)
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

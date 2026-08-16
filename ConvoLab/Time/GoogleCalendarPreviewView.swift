import SwiftUI

@MainActor
@Observable
final class GoogleCalendarPreviewModel: Identifiable {
    enum ContentState: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed(String)
    }

    let id = UUID()
    let request: GoogleCalendarPreviewRequest
    private let service: any GoogleCalendarConnectionServing
    private(set) var state: ContentState = .idle
    private(set) var response: GoogleCalendarPreviewResponse?

    init(service: any GoogleCalendarConnectionServing, request: GoogleCalendarPreviewRequest) {
        self.service = service
        self.request = request
    }

    func load() async {
        guard state != .loading else { return }
        state = .loading
        do {
            let response = try await service.preview(request)
            self.response = response
            state = response.matches.isEmpty ? .empty : .loaded
        } catch {
            response = nil
            state = .failed(Self.safeMessage(for: error))
        }
    }

    func accessibilitySummary(for match: GoogleCalendarPreviewMatch) -> String {
        let start = match.startsAt.formatted(date: .abbreviated, time: .shortened)
        return "\(match.title), \(match.calendarName), \(start), \(durationText(match.durationMs)), \(match.statusLabel), \(match.matchReason)"
    }

    func durationText(_ durationMs: Int64) -> String {
        let minutes = max(0, durationMs / 60_000)
        if durationMs > 0, minutes == 0 { return "<1m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0, remainder > 0 { return "\(hours)h \(remainder)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    private static func safeMessage(for error: Error) -> String {
        if let error = error as? GoogleCalendarConnectionError {
            return error.localizedDescription
        }
        if error is URLError {
            return "Couldn’t reach ConvoLab. Check your connection and try again."
        }
        return "Couldn’t preview Google Calendar events. Please try again."
    }
}

struct GoogleCalendarPreviewView: View {
    let model: GoogleCalendarPreviewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Nothing is imported or synced from this preview.", systemImage: "eye")
                        .accessibilityLabel("Preview only. Nothing is imported or synced from this screen.")
                }
                content
            }
            .navigationTitle("Calendar Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .frame(minHeight: 44)
                }
            }
            .task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("Checking the last 31 days…")
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .empty:
            Section {
                ContentUnavailableView(
                    "No matching lessons",
                    systemImage: "calendar.badge.checkmark",
                    description: Text("No completed events in the last 31 days matched these calendars and title terms.")
                )
                if let response = model.response {
                    LabeledContent("Events scanned", value: "\(response.scannedEventCount)")
                    if response.truncated {
                        Label("The bounded preview limit was reached.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Button("Try Again") { Task { await model.load() } }
                    .frame(minHeight: 44)
            }
        case let .failed(message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(message)")
                Button("Try Again") { Task { await model.load() } }
                    .frame(minHeight: 44)
            }
        case .loaded:
            if let response = model.response {
                Section {
                    ForEach(Array(response.matches.enumerated()), id: \.offset) { _, match in
                        eventRow(match)
                    }
                } header: {
                    Text("Matching events · Last 31 days")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scanned \(response.scannedEventCount) events. Found \(response.matchedEventCount) matches.")
                        if response.truncated {
                            Text("Preview limit reached. Additional matches may not be shown.")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private func eventRow(_ match: GoogleCalendarPreviewMatch) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(match.title)
                .font(.headline)
            Text(match.calendarName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(match.startsAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("·")
                Text(model.durationText(match.durationMs))
            }
            .font(.subheadline)
            HStack(spacing: 8) {
                Label(match.statusLabel, systemImage: match.alreadySynced ? "checkmark.circle.fill" : "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(match.alreadySynced ? .secondary : ConvoLabTheme.navy)
                Text(match.matchReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilitySummary(for: match))
    }
}

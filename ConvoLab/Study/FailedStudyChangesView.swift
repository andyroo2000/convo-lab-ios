import SwiftUI

struct FailedStudyChangesView: View {
    let store: StudyStore

    @Environment(\.dismiss) private var dismiss
    @State private var workingID: String?
    @State private var discarding: FailedStudyChange?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.failedStudyChanges.isEmpty {
                    ContentUnavailableView(
                        "No Failed Changes",
                        systemImage: "checkmark.circle",
                        description: Text("All saved study changes have been handled.")
                    )
                } else {
                    List(store.failedStudyChanges) { change in
                        changeRow(change)
                    }
                }
            }
            .navigationTitle("Failed Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Discard this change?", isPresented: discardConfirmation) {
                Button("Cancel", role: .cancel) { discarding = nil }
                Button("Discard", role: .destructive) {
                    guard let change = discarding else { return }
                    discarding = nil
                    perform(change) {
                        try await store.discardFailedStudyChange(id: change.id)
                    }
                }
            } message: {
                Text(discardMessage)
            }
            .alert("Couldn’t complete that action", isPresented: errorAlert) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
        }
    }

    private func changeRow(_ change: FailedStudyChange) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(change.kind.title, systemImage: change.kind.systemImage)
                .font(.headline)
            Text(change.detail)
                .font(.subheadline)
            Text(change.errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
            Text(metadata(for: change))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Text(change.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if change.isRetryable {
                    Button("Retry") {
                        perform(change) {
                            try await store.retryFailedStudyChange(id: change.id)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(workingID != nil)
                }
                Button("Discard", role: .destructive) {
                    discarding = change
                }
                .buttonStyle(.bordered)
                .disabled(workingID != nil)
            }
            if workingID == change.id {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var discardConfirmation: Binding<Bool> {
        Binding(
            get: { discarding != nil },
            set: { if !$0 { discarding = nil } }
        )
    }

    private var errorAlert: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var discardMessage: String {
        switch discarding?.kind {
        case .cardCreate:
            "The unsaved card and changes that depend on it will be removed from this device."
        case .cardUpdate:
            "The local edit will be discarded. The latest server version will be restored, or the card will be removed if it no longer exists."
        case .cardDelete:
            "The pending deletion will be discarded and the latest server version will be restored."
        case .review:
            "The rejected review will be discarded. The latest server version will be restored, or the card will be removed if it no longer exists."
        case nil:
            "The local change will be discarded."
        }
    }

    private func metadata(for change: FailedStudyChange) -> String {
        let attempts = "\(change.attemptCount) \(change.attemptCount == 1 ? "attempt" : "attempts")"
        let lastAttempt = change.lastAttemptAt.map {
            "Last tried \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? "Not retried yet"
        return "\(attempts) · \(lastAttempt)"
    }

    private func perform(
        _ change: FailedStudyChange,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        workingID = change.id
        Task { @MainActor in
            defer { workingID = nil }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

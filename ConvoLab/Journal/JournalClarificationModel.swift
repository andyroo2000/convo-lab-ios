import Foundation

@MainActor
@Observable
final class JournalClarificationModel {
    private let service: JournalService
    private var entry: JournalEntry?
    private var completion: CheckedContinuation<String?, Never>?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var pendingAnswer: (state: JournalClarification, text: String)?
    private(set) var lastAnswer: String?
    private(set) var active = false
    private(set) var busy = false
    private(set) var canRetry = true
    private(set) var state: JournalClarification?
    private(set) var errorMessage: String?

    init(service: JournalService) { self.service = service }

    func begin(_ entry: JournalEntry) async -> String? {
        guard !active else { return nil }
        generation = UUID()
        let epoch = generation
        lastAnswer = nil
        self.entry = entry
        active = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
                retry()
            }
        } onCancel: {
            Task { @MainActor in
                if self.generation == epoch { self.cancel() }
            }
        }
    }

    func retry() {
        guard let entry, canRetry else { return }
        if let pendingAnswer {
            request { try await self.service.answerClarification(entry, state: pendingAnswer.state, answer: pendingAnswer.text) }
        } else { request { try await self.service.startClarification(entry) } }
    }

    func answer(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry, let state, state.question != nil, !value.isEmpty, !busy, canRetry else { return }
        lastAnswer = value
        pendingAnswer = (state, value)
        request { try await self.service.answerClarification(entry, state: state, answer: value) }
    }

    func cancel() {
        lastAnswer = nil
        generation = UUID()
        work?.cancel()
        work = nil
        finish(nil)
    }

    private func finish(_ id: String?) {
        let pending = completion
        completion = nil
        pendingAnswer = nil
        entry = nil
        active = false
        busy = false
        canRetry = true
        state = nil
        errorMessage = nil
        pending?.resume(returning: id)
    }

    private func request(_ operation: @escaping @MainActor () async throws -> JournalClarification) {
        guard active, !busy else { return }
        let epoch = generation
        busy = true
        errorMessage = nil
        work = Task {
            defer { if generation == epoch { busy = false } }
            do {
                let first = try await operation()
                guard generation == epoch else { return }
                pendingAnswer = nil
                try await receive(first, epoch: epoch)
            } catch is CancellationError { }
            catch {
                if generation == epoch { report(error) }
            }
        }
    }

    private func report(_ error: Error) {
        if case APIClientError.rejected(status: 401, message: _) = error {
            canRetry = false
            errorMessage = "Your session changed or expired. Go back and sign in again to continue."
        } else { errorMessage = error.localizedDescription }
    }

    private func receive(_ first: JournalClarification, epoch: UUID) async throws {
        var next = first
        while true {
            try Task.checkCancellation()
            try service.checkSession()
            guard generation == epoch, let entry else { return }
            guard next.sourceVersion == entry.version else {
                throw APIClientError.rejected(status: 409, message: "The draft changed. Go back and submit it again.")
            }
            state = next
            if next.status == .failed {
                throw APIClientError.rejected(status: 503, message: next.error ?? "Could not check your meaning. Please retry.")
            }
            if next.status == .resolved { finish(next.id); return }
            if !next.status.isPending { return }
            try await Task.sleep(for: .milliseconds(1500))
            next = try await service.clarification(entry)
        }
    }
}

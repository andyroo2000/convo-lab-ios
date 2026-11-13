import Foundation

@MainActor
@Observable
final class JournalConversationAnswer {
    let entry: JournalEntryModel
    private let file: URL
    private var unreadableFile = false
    var body = ""
    private(set) var request: JournalConversationInput?
    private(set) var busy = false
    var errorMessage: String?

    init(entry: JournalEntryModel, rootID: String, analysisID: String) {
        self.entry = entry
        file = entry.store.storage.directory.appending(path: "answers/\(rootID)/\(analysisID)-conversation.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
                body = saved.body; request = saved.request
            }
        } catch { unreadableFile = true; errorMessage = "Your saved answer could not be loaded. Its file has been retained." }
    }

    private struct Saved: Codable { let body: String; let request: JournalConversationInput? }
    func save() {
        do {
            try entry.store.service.checkSession()
            if unreadableFile {
                try FileManager.default.copyItem(at: file, to: file.appendingPathExtension("recovery-" + UUID().uuidString))
                unreadableFile = false
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Saved(body: body, request: request)).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { errorMessage = "Could not save this answer on your device. Keep it open." }
    }

    func submit(questionID: String, refresh: () async -> Bool) async {
        guard !busy, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard body.unicodeScalars.count <= 20000 else { errorMessage = "Keep your answer under 20,000 characters."; return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        let input = request ?? JournalConversationInput(id: ClientIdentifier.ulid().lowercased(), questionId: questionID, body: body)
        request = input
        save()
        do {
            let child = try await entry.store.service.createAnswer(parentID: entry.id, input: input)
            // The child remains saved and editable if requesting feedback fails.
            try await requestFeedback(child)
            guard await refresh() else {
                errorMessage = "Your answer is saved. Reload the conversation to see it."
                return
            }
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } catch is CancellationError { }
        catch {
            if case APIClientError.rejected(let status, _) = error, (400..<500).contains(status), ![401, 408, 429].contains(status) { request = nil; save() }
            errorMessage = error.localizedDescription
        }
    }
    private func requestFeedback(_ child: JournalEntry) async throws {
        do { _ = try await entry.store.service.submit(child) }
        catch is CancellationError { throw CancellationError() }
        catch APIClientError.rejected(status: 401, message: let message) { throw APIClientError.rejected(status: 401, message: message) }
        catch { /* The child form explicitly offers Submit when feedback is absent. */ }
    }
}

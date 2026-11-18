import Foundation

@MainActor
final class JournalCandidateRequests {
    // No actor-bound teardown; avoid the iOS 26.2 isolated-deinit runtime bug.
    nonisolated deinit {}
    private static let engine = TypingEngineActor()
    private var version = 0
    private var busy = false
    private var pending: (version: Int, reading: String, boundaries: [Int])?
    private var debounce: Task<Void, Never>?
    var receive: ((String, [String: Any]) -> Void)?

    func prepare() { Task { _ = try? await Self.engine.prepare() } }

    func cancel() {
        version += 1
        pending = nil
        debounce?.cancel()
    }

    func schedule(reading: String, boundaries: [Int], immediate: Bool = false) {
        cancel()
        guard !reading.isEmpty, reading.range(of: "[a-z]", options: [.regularExpression, .caseInsensitive]) == nil else { return }
        let job = (version, reading, boundaries)
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(immediate ? 0 : 300)) } catch { return }
            self?.pending = job
            self?.run()
        }
    }

    private func run() {
        guard !busy, let job = pending else { return }
        pending = nil
        busy = true
        Task { [weak self] in
            guard let self else { return }
            defer { busy = false; run() }
            for expanded in [false, true] {
                guard job.version == version else { return }
                do {
                    _ = try await Self.engine.prepare()
                    let data = try JSONSerialization.data(withJSONObject: ["reading": job.reading, "boundaries": job.boundaries, "expanded": expanded])
                    let output = try await Self.engine.convert(String(decoding: data, as: UTF8.self))
                    guard job.version == version else { return }
                    if let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] {
                        receive?(job.reading, result)
                    }
                } catch { return } // Kana and exact Latin spelling remain usable while offline inference is unavailable.
            }
        }
    }
}

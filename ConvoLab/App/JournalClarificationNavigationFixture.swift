#if DEBUG
import Foundation

/// Called under the journal fixture lock.
nonisolated struct JournalClarificationNavigationFixture {
    private var step = 0
    private var pendingPolls = 0
    mutating func response(path: String, body: [String: Any]) -> [String: Any]? {
        guard path.contains("/clarification") else { return nil }
        let interactive = ProcessInfo.processInfo.arguments.contains("-journal-clarification-fixture")
        if path.hasSuffix("/answer") {
            step += 1
            if step == 2 && ProcessInfo.processInfo.arguments.contains("-journal-slow-clarification") { pendingPolls = 12 }
        }
        let processing = pendingPolls > 0
        pendingPolls = max(0, pendingPolls - 1)
        let prompts = ["Who was driving?", "Who looked up the movie?"]
        let waiting = interactive && step < prompts.count
        let question: Any = waiting ? ["id": "01arz3ndektsv4rrffq69g5fa\(step)", "prompt": prompts[step], "choices": ["I did", "Molly did"]] : NSNull()
        return ["data": ["id": "01arz3ndektsv4rrffq69g5faz", "sourceVersion": body["expectedVersion"] ?? 1, "revision": step,
                         "status": processing ? "processing" : waiting ? "waiting" : "resolved", "question": question, "error": NSNull(), "updatedAt": "now"]]
    }
}
#endif

#if DEBUG
import Foundation

nonisolated final class JournalReplyNavigationFixture: @unchecked Sendable {
    static let shared = JournalReplyNavigationFixture()
    private let lock = NSLock()
    private var analysis: [String: Any]?
    private var replies: [String: [String: Any]] = [:]

    func response(path: String, method: String?, body: String, initial: String, entry: String) -> String? {
        guard path.hasPrefix("/api/journal/entries/") else { return nil }
        lock.lock(); defer { lock.unlock() }
        let original = object(initial)
        if analysis == nil { analysis = original }
        if path.hasSuffix("/analysis") { return encode(["data": analysis!, "entry": object(entry)]) }
        if path.hasSuffix("/undo") {
            let revision = (analysis?["replyRevision"] as? Int ?? 0) + 1
            analysis = original
            analysis?["replyRevision"] = revision
            return encode(["data": analysis!])
        }
        guard path.contains("/replies/"), let id = path.split(separator: "/").last.map(String.init) else { return nil }
        if method == "PUT" { append(id: id, body: object(body), original: original) }
        return replies[id].map { encode(["data": $0]) }
    }

    private func append(id: String, body: [String: Any], original: [String: Any]) {
        guard replies[id] == nil, var result = original["result"] as? [String: Any] else { return }
        let previous = result["correctedReading"] as? String ?? ""
        let originalText = result["correctedText"] as? String ?? ""
        result["correctedText"] = "友達と見ました。"
        result["correctedReading"] = "友達[ともだち]と見[み]ました。"
        result["entryText"] = originalText + "\n\n友達と見ました。"
        result["entryReading"] = previous + "\n\n友達[ともだち]と見[み]ました。"
        result["previousReading"] = previous
        result["question"] = "どこで見ましたか。"
        result["questionReading"] = "どこで見[み]ましたか。"
        result["questionTranslation"] = "Where did you watch it?"
        let reply: [String: Any] = ["id": id, "parentId": NSNull(), "answer": body["answer"] ?? "",
                                    "status": "ready", "result": result, "error": NSNull()]
        replies[id] = reply
        analysis?["currentReply"] = reply
        let revision = (analysis?["replyRevision"] as? Int ?? 0) + 1
        analysis?["replyRevision"] = revision
    }
    private func object(_ value: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] ?? [:]
    }
    private func encode(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
#endif

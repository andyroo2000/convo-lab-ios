#if DEBUG
import Foundation

/// Root-draft persistence for UI tests, called under the parent fixture lock.
nonisolated struct JournalDraftNavigationFixture {
    private var entries: [String: [String: Any]] = [:]
    private var deleted: Set<String> = []

    mutating func response(path: String, method: String?, body: [String: Any], root: [String: Any]) -> [String: Any]? {
        if path == "/api/journal/entries" { return ["data": listing(root: root), "nextCursor": NSNull()] }
        let prefix = "/api/journal/entries/"
        guard path.hasPrefix(prefix) else { return nil }
        let id = String(path.dropFirst(prefix.count))
        guard !id.contains("/"), id.count == 26 else { return nil }
        switch method {
        case "PUT": return save(id: id, body: body, root: root)
        case "DELETE":
            entries[id] = nil
            deleted.insert(id)
            return [:]
        default: return entries[id].map { ["data": $0] }
        }
    }

    private func listing(root: [String: Any]) -> [[String: Any]] {
        let rootID = root["id"] as? String ?? ""
        let original = deleted.contains(rootID) || entries[rootID] != nil ? [] : [root]
        return original + entries.values.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    }

    private mutating func save(id: String, body: [String: Any], root: [String: Any]) -> [String: Any] {
        var entry = entries[id] ?? root
        entry["id"] = id
        entry["title"] = body["title"] ?? ""
        entry["body"] = body["body"] ?? ""
        entry["entryDate"] = body["entryDate"] ?? "2026-11-22"
        entry["version"] = (body["expectedVersion"] as? Int ?? 0) + 1
        entry["currentAnalysisId"] = NSNull()
        entry["rootEntryId"] = NSNull()
        entries[id] = entry
        deleted.remove(id)
        return ["data": entry]
    }
}
#endif

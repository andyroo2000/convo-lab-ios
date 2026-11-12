#if DEBUG
import Foundation

nonisolated enum JournalDocumentNavigationFixture {
    static func initial(_ analysis: [String: Any]) -> [String: Any] {
        var value = analysis
        value["correctedDocument"] = ["text": "映画を見た。", "reading": "映画[えいが]を見[み]た。",
            "suggestions": [["id": "01arz3ndektsv4rrffq69g5faw:0", "applied": false]]]
        return value
    }

    static func change(path: String, body: [String: Any], analysis: inout [String: Any]?) -> Bool {
        switch path.split(separator: "/").last {
        case "corrected":
            let text = body["text"] as? String ?? ""
            analysis?["correctedDocument"] = ["text": text, "reading": text, "suggestions": []]
        case "suggestion":
            let applied = body["applied"] as? Bool ?? false
            analysis?["correctedDocument"] = ["text": applied ? "映画を見ました。" : "映画を見た。",
                "reading": applied ? "映画[えいが]を見[み]ました。" : "映画[えいが]を見[み]た。",
                "suggestions": [["id": "01arz3ndektsv4rrffq69g5faw:0", "applied": applied]]]
        default: return false
        }
        let revision = (analysis?["replyRevision"] as? Int ?? 0) + 1
        analysis?["replyRevision"] = revision
        return true
    }
}
#endif

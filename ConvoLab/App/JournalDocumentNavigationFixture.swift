#if DEBUG
import Foundation

nonisolated enum JournalDocumentNavigationFixture {
    static func initial(_ analysis: [String: Any]) -> [String: Any] {
        var value = analysis
        value["correctedDocument"] = ["text": "映画を見た。", "reading": "映画[えいが]を見[み]た。",
            "suggestions": [["id": "01arz3ndektsv4rrffq69g5faw:0", "applied": false]]]
        if ProcessInfo.processInfo.arguments.contains("-journal-long-correction") {
            var result = value["result"] as? [String: Any] ?? [:]
            result["segments"] = [["text": "昨日友達と映画を見た。", "reading": "昨日[きのう]友達[ともだち]と映画[えいが]を見[み]た。", "kind": "correction",
                "replacement": "昨日友達と映画を見ました。その後で一緒に夕食を食べました。",
                "replacementReading": "昨日[きのう]友達[ともだち]と映画[えいが]を見[み]ました。その後[あと]で一緒[いっしょ]に夕食[ゆうしょく]を食[た]べました。",
                "explanation": String(repeating: "見ました is the polite past form. Use it to describe watching a movie with friends. ", count: 8) + "End of explanation."]]
            value["result"] = result
        }
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

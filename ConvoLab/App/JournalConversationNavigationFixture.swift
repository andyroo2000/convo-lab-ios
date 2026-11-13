#if DEBUG
import Foundation

/// Called under the parent fixture lock.
nonisolated struct JournalConversationNavigationFixture {
    private var nodes: [[String: Any]] = []
    mutating func response(path: String, method: String?, body: [String: Any], root: [String: Any], analysis: [String: Any], tutor: inout JournalTutorNavigationFixture) -> [String: Any]? {
        if path.hasSuffix("/conversation") {
            if method == "POST" { return create(body: body, root: root, analysis: analysis, tutor: &tutor) }
            return ["data": nodes]
        }
        guard let node = nodes.first(where: { path.contains(($0["entry"] as? [String: Any])?["id"] as? String ?? "missing") }),
              let entry = node["entry"] as? [String: Any], let feedback = node["analysis"] as? [String: Any] else { return nil }
        if path.hasSuffix("/analysis") { return ["data": feedback, "entry": entry] }
        if path.hasSuffix("/submit") { return ["data": feedback] }
        if path.hasSuffix("/question") {
            var input = body
            input["replyId"] = feedback["id"]
            return tutor.response(path: path, method: method, body: input, analysis: feedback).map { ["data": $0] }
        }
        if let question = node["question"], path.hasSuffix("/retry") { return ["data": question] }
        return ["data": entry]
    }
    private mutating func create(body: [String: Any], root: [String: Any], analysis: [String: Any], tutor: inout JournalTutorNavigationFixture) -> [String: Any] {
        let id = body["id"] as! String
        if let existing = nodes.first(where: { ($0["entry"] as? [String: Any])?["id"] as? String == id }) { return ["data": existing["entry"]!] }
        var entry = root
        entry["id"] = id; entry["rootEntryId"] = root["id"]; entry["body"] = body["body"]
        var childAnalysis = analysis
        childAnalysis["id"] = id
        var result = analysis["result"] as! [String: Any]
        result["correctedText"] = "友達と見ました。"; result["correctedReading"] = "友達[ともだち]と見[み]ました。"
        result["question"] = "どこで見ましたか。"; result["questionReading"] = "どこで見[み]ましたか。"; result["questionTranslation"] = "Where did you watch it?"
        result["segments"] = [["text": body["body"]!, "reading": body["body"]!, "kind": "plain", "suggestion": NSNull(), "suggestionReading": NSNull(), "explanation": NSNull(), "explanationReading": NSNull()]]
        childAnalysis["result"] = result
        childAnalysis["correctedDocument"] = ["text": "友達と見ました。", "reading": "友達[ともだち]と見[み]ました。", "suggestions": []]
        let question = tutor.response(path: "/question", method: "POST", body: [:], analysis: analysis)!
        nodes.append(["entry": entry, "analysis": childAnalysis, "question": question, "parentEntryId": root["id"]!])
        return ["data": entry]
    }
}
#endif

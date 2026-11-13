#if DEBUG
import Foundation

/// Called while JournalReplyNavigationFixture holds its lock.
nonisolated struct JournalTutorNavigationFixture {
    private var selected: String?
    private var questions: [String: [String: Any]] = [:]
    private let tutors: [[String: String]] = [
        ["id": "hana", "name": "Hana", "gender": "F", "avatar": "hana-v1"],
        ["id": "ren", "name": "Ren", "gender": "M", "avatar": "ren-v1"]
    ]

    mutating func response(path: String, method: String?, body: [String: Any], analysis: [String: Any]) -> [String: Any]? {
        if path == "/api/journal/tutor" {
            if method == "PUT" { selected = body["tutorId"] as? String }
            return ["selectedId": selected as Any? ?? NSNull(), "tutors": tutors]
        }
        guard path.hasSuffix("/question") else { return nil }
        let key = body["replyId"] as? String ?? "entry"
        let reply = analysis["currentReply"] as? [String: Any]
        let feedback = (reply?["result"] ?? analysis["result"]) as? [String: Any] ?? [:]
        var question = questions[key] ?? ["id": "01arz3ndektsv4rrffq69g5fax", "text": feedback["question"] ?? "",
            "reading": feedback["questionReading"] ?? "", "translation": feedback["questionTranslation"] ?? "", "tutor": NSNull()]
        if question["tutor"] is NSNull { question["tutor"] = tutors.first { $0["id"] == selected } as Any? ?? NSNull() }
        questions[key] = question
        return question
    }
}
#endif

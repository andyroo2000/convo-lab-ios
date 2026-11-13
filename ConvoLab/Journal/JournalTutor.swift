import Foundation

nonisolated struct JournalTutor: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let gender: String
    let avatar: String
    var imageName: String { avatar == "hana-v1" ? "JournalTutorHana" : "JournalTutorRen" }
}
nonisolated struct JournalTutorPreferences: Codable, Sendable {
    let selectedId: String?
    let tutors: [JournalTutor]
}
nonisolated struct JournalTutorChoice: Encodable, Sendable { let tutorId: String }
nonisolated struct JournalQuestionInput: Encodable, Sendable {
    let analysisId: String
    let replyId: String?
}
nonisolated struct JournalTutorQuestion: Codable, Identifiable, Sendable {
    let id: String
    let text: String
    let reading: String
    let translation: String
    let tutor: JournalTutor?
}

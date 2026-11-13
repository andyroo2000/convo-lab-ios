import Foundation

nonisolated struct JournalTutor: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let gender: String
    let avatar: String
    var avatarUrl: String? = nil
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
    var audio: JournalQuestionAudioState? = nil
}

nonisolated struct JournalQuestionAudioState: Codable, Sendable {
    let status: String
    let error: String?
    var waiting: Bool { status == "queued" || status == "processing" }
}

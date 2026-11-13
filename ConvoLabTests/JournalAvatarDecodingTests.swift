import Foundation
import XCTest
@testable import ConvoLab

final class JournalAvatarDecodingTests: XCTestCase {
    func testVoiceAndTutorDecodePresentMissingAndNullAvatarURLs() throws {
        for value in [nil, NSNull(), "/api/journal/avatars/male-01-v1"] as [Any?] {
            var voice: [String: Any] = ["id": "haru", "name": "Haru (M)"]
            var tutor: [String: Any] = ["id": "ren", "name": "Ren", "gender": "M", "avatar": "ren-v1"]
            voice["avatarUrl"] = value
            tutor["avatarUrl"] = value
            let decodedVoice = try JSONDecoder().decode(JournalVoice.self, from: JSONSerialization.data(withJSONObject: voice))
            let decodedTutor = try JSONDecoder().decode(JournalTutor.self, from: JSONSerialization.data(withJSONObject: tutor))
            XCTAssertEqual(decodedVoice.avatarUrl, value as? String)
            XCTAssertEqual(decodedTutor.avatarUrl, value as? String)
        }
    }
}

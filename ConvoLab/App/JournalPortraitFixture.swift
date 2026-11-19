#if DEBUG
import Foundation

nonisolated enum JournalPortraitFixture {
    static func url(_ portrait: String) -> String {
        guard let base = ProcessInfo.processInfo.environment["JOURNAL_FIXTURE_AVATARS"] else { return "" }
        return base + "/" + portrait + "-preview.webp"
    }

    static var voices: String {
        let data = ["data": [
            ["id": "haru", "name": "Haru (M)", "avatarUrl": url("professor-female")],
            ["id": "yua", "name": "Yua (F)", "avatarUrl": url("male-02")]
        ]]
        guard let encoded = try? JSONSerialization.data(withJSONObject: data) else { return "{\"data\":[]}" }
        return String(decoding: encoded, as: UTF8.self)
    }
}
#endif

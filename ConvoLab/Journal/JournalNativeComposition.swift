import Foundation
import JavaScriptCore

struct JournalInputSnapshot: Decodable {
    let text: String
    let caret: Int
    let composition: [Int]?
    let section: [Int]?
    let choices: [String]
    let reading: String
    let highlighted: Int
    let boundaries: [Int]
}

/// Reuses the playground's kana composer and whole-phrase section alignment.
/// JavaScriptCore runs these small synchronous edits without a web text field.
@MainActor
final class JournalNativeComposition {
    // No actor-bound teardown; avoid the iOS 26.2 isolated-deinit runtime bug.
    nonisolated deinit {}
    private let context: JSContext
    private let session: JSValue
    private(set) var state: JournalInputSnapshot

    init?() {
        guard let context = JSContext(),
              let url = Bundle.main.url(forResource: "journal-native", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        context.evaluateScript(source)
        guard let session = context.objectForKeyedSubscript("makeJournalSession")?.call(withArguments: []),
              let state = Self.decode(session.invokeMethod("snapshot", withArguments: [])) else { return nil }
        self.context = context
        self.session = session
        self.state = state
    }

    @discardableResult
    func call(_ method: String, _ arguments: [Any] = []) -> JournalInputSnapshot {
        if let result = Self.decode(session.invokeMethod(method, withArguments: arguments)) { state = result }
        return state
    }

    func takeConfirmedConversions() -> [[String: Any]] {
        session.invokeMethod("takeConfirmedConversions", withArguments: [])?.toArray() as? [[String: Any]] ?? []
    }

    private static func decode(_ value: JSValue?) -> JournalInputSnapshot? {
        guard let object = value?.toDictionary(),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(JournalInputSnapshot.self, from: data)
    }
}

import Foundation

nonisolated struct JournalSentenceTiming: Codable, Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

nonisolated struct JournalTimedRecording: Codable, Sendable {
    let audioBase64: String
    let sentences: [JournalSentenceTiming]

    func audioData() throws -> Data {
        guard let data = Data(base64Encoded: audioBase64), !data.isEmpty else { throw APIClientError.invalidResponse }
        return data
    }
}

nonisolated enum JournalSentenceTimeline {
    static func current(_ sentences: [JournalSentenceTiming], at position: Double) -> Int? {
        sentences.lastIndex { position + 0.001 >= $0.start && position < $0.end }
    }

    static func adjacent(_ sentences: [JournalSentenceTiming], at position: Double, direction: Int) -> Double? {
        guard !sentences.isEmpty else { return nil }
        let current = sentences.lastIndex { position + 0.001 >= $0.start } ?? 0
        return sentences[min(max(current + direction, 0), sentences.count - 1)].start
    }

    static func ranges(_ sentences: [JournalSentenceTiming], text: String) -> [NSRange] {
        guard sentences.map(\.text).joined() == text else { return [] }
        var offset = 0
        return sentences.map { sentence in
            defer { offset += sentence.text.utf16.count }
            return NSRange(location: offset, length: sentence.text.utf16.count)
        }
    }
}

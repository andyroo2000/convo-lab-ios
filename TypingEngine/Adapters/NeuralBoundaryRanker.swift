public import Foundation

#if Zenzai || ZenzaiCPU
// The same pinned Zenz model scores complete boundary-compatible sentences.
// A separate context prevents scoring from disturbing live-conversion caches.
public final class NeuralBoundaryRanker {
    private let context: ZenzContext

    public init(modelURL: URL) throws {
        context = try ZenzContext.createContext(path: modelURL.path)
        _ = try score(reading: "はし", text: "箸")
    }

    public func rank(_ candidates: [Candidate], reading: String) throws -> [Candidate] {
        var seen = Set<String>()
        let katakana = reading.applyingTransform(.hiraganaToKatakana, reverse: false)
        let shortlist = candidates.filter {
            $0.data.map(\.ruby).joined() == katakana && seen.insert($0.text).inserted
        }.prefix(160)
        let scored = try shortlist.enumerated().map { index, original in
            var candidate = original
            let neuralScore = try score(reading: reading, text: original.text)
            candidate.value = PValue(neuralScore)
            return (index: index, candidate: candidate, score: neuralScore)
        }
        return scored.sorted {
            if $0.score == $1.score { return $0.index < $1.index }
            return $0.score > $1.score
        }.map(\.candidate)
    }

    private func score(reading: String, text: String) throws -> Float {
        let kana = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
        let prompt = "\u{EE00}\(kana)\u{EE01}"
        let output = text.replacingOccurrences(of: " ", with: "\u{3000}")
        let value = context.evaluate(text: prompt + output, ignorePrompt: prompt)
        guard value.isFinite else { throw RankingError.invalidScore }
        return value
    }

    private enum RankingError: Error { case invalidScore }
}
#endif

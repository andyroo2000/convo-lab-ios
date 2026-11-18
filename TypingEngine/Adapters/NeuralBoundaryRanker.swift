public import Foundation

#if Zenzai || ZenzaiCPU
// The same pinned Zenz model scores complete boundary-compatible sentences.
// The owning engine serializes requests. Boundary scoring shares model weights
// with ordinary conversion, while retaining its own multi-sequence KV cache.
public final class NeuralBoundaryRanker {
    private let context: ZenzContext
    private let batch: BoundaryBatchScorer?
    private var cache = BoundaryScoreCache()

    public init(converter: KanaKanjiConverter, modelURL: URL) throws {
        guard let context = converter.getModel(modelURL: modelURL)?.zenzContext
        else { throw RankingError.modelUnavailable }
        self.context = context
        batch = try context.makeBoundaryBatchScorer()
        _ = try scores(reading: "はし", texts: ["箸"])
    }

    public func rank(_ candidates: [Candidate], reading: String) throws -> [Candidate] {
        var seen = Set<String>()
        let katakana = reading.applyingTransform(.hiraganaToKatakana, reverse: false)
        let shortlist = candidates.filter {
            $0.data.map(\.ruby).joined() == katakana && seen.insert($0.text).inserted
        }.prefix(160)
        let values = try scores(reading: reading, texts: shortlist.map(\.text))
        let scored = shortlist.enumerated().map { index, original in
            var candidate = original
            let neuralScore = values[index]
            candidate.value = PValue(neuralScore)
            return (index: index, candidate: candidate, score: neuralScore)
        }
        return scored.sorted {
            if $0.score == $1.score { return $0.index < $1.index }
            return $0.score > $1.score
        }.map(\.candidate)
    }

    private func scores(reading: String, texts: [String]) throws -> [Float] {
        let kana = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
        let prompt = "\u{EE00}\(kana)\u{EE01}"
        let outputs = texts.map { $0.replacingOccurrences(of: " ", with: "\u{3000}") }
        cache.begin(reading: prompt)
        let missing = outputs.filter { cache.score(for: $0) == nil }
        let values = try context.boundaryScores(texts: missing, prompt: prompt, batch: batch)
        guard values.allSatisfy(\.isFinite) else { throw RankingError.invalidScore }
        // Keep this request's scores separately: cache eviction must never lose
        // a value that is needed by the current full candidate list.
        let fresh = Dictionary(zip(missing, values), uniquingKeysWith: { first, _ in first })
        let result = try outputs.map { text in
            guard let value = cache.score(for: text) ?? fresh[text]
            else { throw RankingError.invalidScore }
            return value
        }
        for (text, value) in fresh {
            cache.store(value, for: text)
        }
        return result
    }

    private enum RankingError: Error { case invalidScore, modelUnavailable }
}
#endif

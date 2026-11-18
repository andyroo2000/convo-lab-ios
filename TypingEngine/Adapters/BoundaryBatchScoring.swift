// Appended beside ZenzContext: share its model weights, but keep an independent
// multi-sequence KV cache. Retaining the owner keeps the model alive until the
// batch context has been freed. All calls run on the owning engine's actor.
extension ZenzContext {
    func resetForTyping() {
        // A fresh phrase needs empty KV and prefix state, not a new GPU context
        // and all of its buffers. No learning or sampling state is retained.
        llama_kv_cache_clear(context)
        prevInput = []
        prevPrompt = []
    }

    func makeBoundaryBatchScorer() throws -> BoundaryBatchScorer? {
        #if ZenzaiCPU || targetEnvironment(simulator)
        // CPU quantized matrix kernels change rounding with batch shape. Keep
        // upstream's exact scoring path on CPU instead of weakening parity.
        return nil
        #else
        var params = Self.ctx_params
        // The KV pool is shared across sequences, not reserved per sentence.
        // Each decode is capped at 512 TOTAL tokens and clears the pool first.
        params.n_ctx = 512
        params.n_seq_max = 16
        params.n_batch = 512
        params.n_ubatch = 512
        return try BoundaryBatchScorer(owner: self, model: model, params: params)
        #endif
    }

    func boundaryScores(texts: [String], prompt: String, batch: BoundaryBatchScorer?) throws -> [Float] {
        guard let batch else {
            return texts.map { evaluate(text: prompt + $0, ignorePrompt: prompt) }
        }
        let sentences = texts.map { tokenize(text: prompt + $0, add_bos: true, add_eos: true) }
        let promptCount = tokenize(text: prompt, add_bos: true).count
        return try batch.evaluate(sentences, promptCount: promptCount, vocabulary: Int(llama_vocab_n_tokens(vocab)))
    }
}

final class BoundaryBatchScorer {
    private let owner: ZenzContext
    private let context: OpaquePointer
    private let batchCapacity = 512
    private let sequenceCapacity = 16

    init(owner: ZenzContext, model: OpaquePointer, params: llama_context_params) throws {
        self.owner = owner
        guard let context = llama_init_from_model(model, params) else { throw ZenzError.couldNotLoadContext }
        self.context = context
    }

    deinit { llama_free(context) }

    func evaluate(_ sentences: [[llama_token]], promptCount: Int, vocabulary: Int) throws -> [Float] {
        var scores: [Float] = []
        var offset = 0
        while offset < sentences.count {
            let chunk = try nextChunk(sentences, offset: offset)
            scores += try decode(chunk, promptCount: promptCount, vocabulary: vocabulary)
            offset += chunk.count
        }
        return scores
    }

    private func nextChunk(_ sentences: [[llama_token]], offset: Int) throws -> [[llama_token]] {
        var chunk: [[llama_token]] = []
        var count = 0
        for sentence in sentences.dropFirst(offset).prefix(sequenceCapacity) {
            guard sentence.count <= batchCapacity else { throw BatchFailure.sentenceTooLong }
            if count + sentence.count > batchCapacity { break }
            chunk.append(sentence)
            count += sentence.count
        }
        return chunk
    }

    private func decode(_ sentences: [[llama_token]], promptCount: Int, vocabulary: Int) throws -> [Float] {
        llama_kv_cache_clear(context)
        var batch = llama_batch_init(Int32(batchCapacity), 0, 1)
        defer { llama_batch_free(batch) }
        for (sequence, sentence) in sentences.enumerated() {
            for (position, token) in sentence.enumerated() {
                let output = position >= promptCount - 1 && position < sentence.count - 1
                let index = Int(batch.n_tokens)
                batch.token[index] = token
                batch.pos[index] = Int32(position)
                batch.n_seq_id[index] = 1
                batch.seq_id[index]![0] = Int32(sequence)
                batch.logits[index] = output ? 1 : 0
                batch.n_tokens += 1
            }
        }
        guard llama_decode(context, batch) == 0, let logits = llama_get_logits(context)
        else { throw BatchFailure.decodeFailed }
        return normalizedScores(sentences, promptCount: promptCount, vocabulary: vocabulary, logits: logits)
    }

    private func normalizedScores(_ sentences: [[llama_token]], promptCount: Int, vocabulary: Int,
                                  logits: UnsafeMutablePointer<Float>) -> [Float] {
        var row = 0
        return sentences.map { sentence in
            var score: Float = 0
            for token in sentence.dropFirst(promptCount) {
                var denominator: Float = 0
                for word in 0..<vocabulary { denominator += expf(logits[row + word]) }
                score += logits[row + Int(token)] - logf(denominator)
                row += vocabulary
            }
            return score
        }
    }

    private enum BatchFailure: Error { case sentenceTooLong, decodeFailed }
}

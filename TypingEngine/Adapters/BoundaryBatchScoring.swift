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
        // Reserve one prompt sequence plus 16 candidates in a 512-token pool.
        params.n_ctx = 512
        params.n_seq_max = 17
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
        // An entirely cached candidate pool needs no inference.
        guard let first = sentences.first else { return [] }
        try validate(sentences, promptCount: promptCount)
        let firstScores = try decodePrompt(first, count: promptCount, vocabulary: vocabulary)
        var scores: [Float] = []
        var offset = 0
        while offset < sentences.count {
            let chunk = nextChunk(sentences, offset: offset, promptCount: promptCount)
            scores += try decode(chunk, promptCount: promptCount, firstScores: firstScores, vocabulary: vocabulary)
            offset += chunk.count
        }
        return scores
    }

    private func validate(_ sentences: [[llama_token]], promptCount: Int) throws {
        guard promptCount > 0, let first = sentences.first, promptCount < first.count
        else { throw BatchFailure.invalidPrompt }
        for sentence in sentences {
            guard sentence.count <= batchCapacity else { throw BatchFailure.sentenceTooLong }
            guard sentence.count > promptCount,
                  sentence.prefix(promptCount).elementsEqual(first.prefix(promptCount))
            else { throw BatchFailure.invalidPrompt }
        }
    }

    private func decodePrompt(_ sentence: [llama_token], count: Int, vocabulary: Int) throws -> [Float] {
        llama_kv_cache_clear(context)
        var batch = llama_batch_init(Int32(batchCapacity), 0, 1)
        defer { llama_batch_free(batch) }
        for position in 0..<count {
            append(sentence[position], position: position, sequence: 0, to: &batch)
            batch.logits[position] = position == count - 1 ? 1 : 0
        }
        try run(batch)
        guard let logits = llama_get_logits(context) else { throw BatchFailure.decodeFailed }
        let norm = normalization(logits, vocabulary: vocabulary)
        // These logits predict the first continuation token, including EOS for
        // an empty continuation. Copy them before decoding any suffix batches.
        return (0..<vocabulary).map { logits[$0] - norm }
    }

    private func nextChunk(_ sentences: [[llama_token]], offset: Int, promptCount: Int) -> [[llama_token]] {
        var chunk: [[llama_token]] = []
        var count = promptCount
        for sentence in sentences.dropFirst(offset).prefix(sequenceCapacity) {
            let suffixCount = sentence.count - promptCount - 1
            if count + suffixCount > batchCapacity { break }
            chunk.append(sentence)
            count += suffixCount
        }
        return chunk
    }

    private func decode(_ sentences: [[llama_token]], promptCount: Int,
                        firstScores: [Float], vocabulary: Int) throws -> [Float] {
        // Keep prompt-only KV rows; discard all previous candidate suffixes.
        llama_kv_cache_seq_keep(context, 0)
        var batch = llama_batch_init(Int32(batchCapacity), 0, 1)
        defer { llama_batch_free(batch) }
        for (index, sentence) in sentences.enumerated() {
            let sequence = Int32(index + 1)
            llama_kv_cache_seq_cp(context, 0, sequence, 0, Int32(promptCount))
            for position in promptCount..<(sentence.count - 1) {
                append(sentence[position], position: position, sequence: sequence, to: &batch)
            }
        }
        try run(batch)
        return try normalizedScores(sentences, promptCount: promptCount, firstScores: firstScores, vocabulary: vocabulary)
    }

    private func append(_ token: llama_token, position: Int, sequence: Int32, to batch: inout llama_batch) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = Int32(position)
        batch.n_seq_id[index] = 1
        batch.seq_id[index]![0] = sequence
        batch.logits[index] = 1
        batch.n_tokens += 1
    }

    private func run(_ batch: llama_batch) throws {
        guard batch.n_tokens > 0 else { return }
        guard llama_decode(context, batch) == 0 else { throw BatchFailure.decodeFailed }
    }

    private func normalization(_ logits: UnsafeMutablePointer<Float>, vocabulary: Int) -> Float {
        var denominator: Float = 0
        for word in 0..<vocabulary { denominator += expf(logits[word]) }
        return logf(denominator)
    }

    private func normalizedScores(_ sentences: [[llama_token]], promptCount: Int,
                                  firstScores: [Float], vocabulary: Int) throws -> [Float] {
        var row = 0
        return try sentences.map { sentence in
            var score = firstScores[Int(sentence[promptCount])]
            for token in sentence.dropFirst(promptCount + 1) {
                guard let logits = llama_get_logits(context)?.advanced(by: row * vocabulary)
                else { throw BatchFailure.decodeFailed }
                score += logits[Int(token)] - normalization(logits, vocabulary: vocabulary)
                row += 1
            }
            guard score.isFinite else { throw BatchFailure.invalidScore }
            return score
        }
    }

    private enum BatchFailure: Error { case sentenceTooLong, invalidPrompt, decodeFailed, invalidScore }
}

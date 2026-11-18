// Personal learning is disabled in both playgrounds. Keep this API unavailable
// at runtime instead of shipping the unrelated personalization tokenizer.
public struct ZenzTokenizer { public init() {} }
public struct EfficientNGram {
    public init(baseFilename: String, n: Int, d: Double, tokenizer: ZenzTokenizer) {
        preconditionFailure("Typing playground does not enable personalization")
    }
    public func bulkPredict(_ tokens: some BidirectionalCollection<Int>) -> [Double] {
        preconditionFailure("Typing playground does not enable personalization")
    }
}

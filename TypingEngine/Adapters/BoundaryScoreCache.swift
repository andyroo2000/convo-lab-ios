// Scores depend on the complete reading and output, not the selected cuts.
// Keep only the current reading and bound the number of retained sentences.
struct BoundaryScoreCache {
    private var reading = ""
    private var values: [String: Float] = [:]
    private let capacity = 512

    mutating func begin(reading: String) {
        if self.reading != reading {
            self.reading = reading
            values.removeAll(keepingCapacity: true)
        }
    }

    func score(for text: String) -> Float? { values[text] }

    mutating func store(_ value: Float, for text: String) {
        if values.count == capacity { values.removeAll(keepingCapacity: true) }
        values[text] = value
    }
}

import Foundation

// ConvoLab adapter for pinned AzooKey v0.11.2. Compiled inside the upstream
// module to expose the same full-phrase query used by its bundled CLI.
extension KanaKanjiConverter {
    public func requestWholePhraseCandidates(
        _ input: ComposingText,
        options: ConvertRequestOptions
    ) -> ConversionResult {
        var wholePhraseOptions = options
        wholePhraseOptions.requestQuery = .完全一致
        return requestCandidates(input, options: wholePhraseOptions)
    }
}

// A full-input lattice with explicit reading cuts. Only dictionary edges that
// cross a requested cut are removed; scoring still connects the entire phrase.
// This deliberately does not pretend the neural model supports forced cuts.
public final class BoundaryCandidateConverter {
    private let converter: Kana2Kanji
    private let state: DicdataStoreState

    public init(dicdataStore: DicdataStore) {
        converter = Kana2Kanji(dicdataStore: dicdataStore)
        state = dicdataStore.prepareState()
    }

    public func candidates(
        reading: String, boundaries: [Int], options: ConvertRequestOptions
    ) -> [Candidate] {
        var input = ComposingText()
        input.insertAtCursorPosition(reading, inputStyle: .direct)
        state.updateKeyboardLanguage(options.keyboardLanguage)
        state.updateUserDictionaryURL(options.sharedContainerURL)
        state.updateLearningConfig(LearningConfig(
            learningType: options.learningType, maxMemoryCount: options.maxMemoryCount,
            memoryURL: options.memoryDirectoryURL
        ))
        let cuts = characterCuts(reading, boundaries: boundaries)
        let nodes = (0..<reading.count).map { start in
            let end = cuts.first(where: { $0 > start }) ?? reading.count
            return converter.dicdataStore.lookupDicdata(
                composingText: input,
                inputRange: (start, start..<end),
                surfaceRange: (start, start..<end),
                needTypoCorrection: false,
                state: state
            )
        }
        let lattice = Lattice(inputCount: input.input.count, surfaceCount: reading.count, rawNodes: nodes)
        let result = converter.kana2lattice_all(
            input, N_best: 128, needTypoCorrection: false,
            preprocessedLattice: lattice, dicdataStoreState: state
        )
        return result.result.getCandidateData()
            .map { converter.processClauseCandidate($0) }
            .sorted { $0.value > $1.value }
    }

    private func characterCuts(_ reading: String, boundaries: [Int]) -> [Int] {
        var utf16Offset = 0
        var cuts: [Int] = []
        for (index, character) in reading.enumerated() {
            utf16Offset += String(character).utf16.count
            if boundaries.contains(utf16Offset) { cuts.append(index + 1) }
        }
        return cuts
    }
}

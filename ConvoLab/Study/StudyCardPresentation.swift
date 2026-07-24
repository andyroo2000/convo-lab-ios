import Foundation

struct StudyCardPresentation: Equatable, Sendable {
    enum TextRole: String, Sendable {
        case restoredText
        case meaning
        case sentenceJapanese
        case sentenceEnglish
        case note
    }

    struct TextBlock: Equatable, Identifiable, Sendable {
        let id: String
        let role: TextRole
        let text: String
    }

    struct Face: Equatable, Sendable {
        let heading: String?
        let supportingText: String?
        let textBlocks: [TextBlock]
        let audioURL: URL?
        let imageURL: URL?
        let isMediaLed: Bool
    }

    let front: Face
    let back: Face
}

extension StudyCard {
    var isEditableInBasicForm: Bool {
        cardType == "recognition"
            && prompt.firstNonEmptyString(for: ["cueText"]) != nil
            && prompt.mediaURL(for: "cueAudio") == nil
            && prompt.mediaURL(for: "cueImage") == nil
    }

    var presentation: StudyCardPresentation {
        let promptAudioURL = prompt.mediaURL(for: "cueAudio")
        let promptImageURL = prompt.mediaURL(for: "cueImage")
        let answerAudioURL = answer.mediaURL(for: "answerAudio")
        let answerImageURL = answer.mediaURL(for: "answerImage") ?? promptImageURL

        if cardType == "cloze" {
            let rawClozeText = prompt.firstNonEmptyString(for: ["clozeText"])
            let cloze = ClozePresentation(
                rawText: rawClozeText ?? prompt.firstNonEmptyString(for: ["clozeDisplayText"])
            )
            let frontHeading = cloze.displayText?.studyDisplayText

            let notes = answer.studyNotes.map { note in
                StudyCardPresentation.TextBlock(
                    id: "note-\(note.offset)",
                    role: .note,
                    text: note.element
                )
            }
            let meaning = answer.firstNonEmptyString(for: ["meaning"]).map {
                StudyCardPresentation.TextBlock(
                    id: "meaning",
                    role: .meaning,
                    text: $0.studyDisplayText
                )
            }
            let restoredText = answer.firstNonEmptyString(
                for: ["restoredTextReading", "restoredText"]
            ) ?? cloze.restoredText

            return StudyCardPresentation(
                front: .init(
                    heading: frontHeading,
                    supportingText: prompt.firstNonEmptyString(
                        for: ["clozeResolvedHint", "clozeHint"]
                    )?.studyDisplayText,
                    textBlocks: [],
                    audioURL: nil,
                    imageURL: promptImageURL,
                    isMediaLed: promptImageURL != nil
                ),
                back: .init(
                    heading: restoredText?.studyDisplayText,
                    supportingText: nil,
                    textBlocks: [meaning].compactMap(\.self) + notes,
                    audioURL: answerAudioURL,
                    imageURL: answerImageURL,
                    isMediaLed: false
                )
            )
        }

        let cueText = prompt.firstNonEmptyString(for: ["cueText"])
        let cueMeaning = prompt.firstNonEmptyString(for: ["cueMeaning"])
        let isMediaLed = (promptAudioURL != nil || promptImageURL != nil) && cueText == nil
        let visualLabels = Set(["名詞", "動詞", "形容詞", "副詞", "表現"])
        let mediaLabel: String? = if
            cardType == "production",
            isMediaLed,
            promptImageURL != nil,
            promptAudioURL == nil,
            let cueMeaning,
            visualLabels.contains(cueMeaning)
        {
            cueMeaning.studyDisplayText
        } else {
            nil
        }

        var details: [StudyCardPresentation.TextBlock] = []
        func appendDetail(_ role: StudyCardPresentation.TextRole, keys: [String]) {
            guard let value = answer.firstNonEmptyString(for: keys) else { return }
            details.append(.init(id: role.rawValue, role: role, text: value.studyDisplayText))
        }
        appendDetail(.restoredText, keys: ["restoredText"])
        appendDetail(.meaning, keys: ["meaning"])
        appendDetail(.sentenceJapanese, keys: ["sentenceJp"])
        appendDetail(.sentenceEnglish, keys: ["sentenceEn"])
        details.append(contentsOf: answer.studyNotes.map { note in
            .init(id: "note-\(note.offset)", role: .note, text: note.element)
        })

        return StudyCardPresentation(
            front: .init(
                heading: isMediaLed ? nil : cueText?.studyDisplayText,
                supportingText: isMediaLed ? mediaLabel : cueMeaning?.studyDisplayText,
                textBlocks: [],
                audioURL: promptAudioURL,
                imageURL: promptImageURL,
                isMediaLed: isMediaLed
            ),
            back: .init(
                heading: answer.firstNonEmptyString(
                    for: ["expressionReading", "expression"]
                )?.studyDisplayText
                    ?? prompt.firstNonEmptyString(for: ["cueReading"])?.studyDisplayText,
                supportingText: nil,
                textBlocks: details,
                audioURL: answerAudioURL,
                imageURL: answerImageURL,
                isMediaLed: false
            )
        )
    }
}

private extension JSONValue {
    func mediaURL(for key: String) -> URL? {
        guard
            let media = self[key],
            let rawURL = media["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty
        else {
            return nil
        }
        return URL(string: rawURL)
    }

    var studyNotes: [(offset: Int, element: String)] {
        guard let notes = firstNonEmptyString(for: ["notes"]) else { return [] }
        return notes.studyPlainText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .map { $0.replacingOccurrences(of: #"^[•\-\s]+"#, with: "", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).studyDisplayText }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { ($0.offset, $0.element) }
    }
}

private struct ClozePresentation {
    let displayText: String?
    let restoredText: String?

    init(rawText: String?) {
        guard let rawText = rawText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty
        else {
            displayText = nil
            restoredText = nil
            return
        }

        let normalized = rawText.normalizedLooseClozeText
        guard normalized.containsCanonicalClozeMarkup else {
            // A resolved legacy sentence has no reliable indication of which text
            // should be hidden. Keep it for the revealed face, but never expose it
            // as the prompt.
            displayText = nil
            restoredText = normalized.studyPlainText.nilIfEmpty
            return
        }

        let pattern = #"\{\{c(\d+)::(.*?)(?:::(.*?))?\}\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            displayText = normalized.studyPlainText.nilIfEmpty
            restoredText = normalized.studyPlainText.nilIfEmpty
            return
        }

        let fullRange = NSRange(normalized.startIndex..., in: normalized)
        let matches = expression.matches(in: normalized, range: fullRange)
        var display = ""
        var restored = ""
        var cursor = normalized.startIndex

        for match in matches {
            guard
                let tokenRange = Range(match.range(at: 0), in: normalized),
                let ordinalRange = Range(match.range(at: 1), in: normalized),
                let contentRange = Range(match.range(at: 2), in: normalized)
            else {
                continue
            }
            let leading = normalized[cursor..<tokenRange.lowerBound]
            let content = normalized[contentRange]
            display += leading
            restored += leading
            restored += content
            display += normalized[ordinalRange] == "1" ? "[...]" : String(content)
            cursor = tokenRange.upperBound
        }
        display += normalized[cursor...]
        restored += normalized[cursor...]

        displayText = display.studyPlainText.nilIfEmpty
        restoredText = restored.studyPlainText.nilIfEmpty
    }
}

private extension String {
    var containsCanonicalClozeMarkup: Bool {
        range(of: #"\{\{c\d+::"#, options: .regularExpression) != nil
    }

    var normalizedLooseClozeText: String {
        guard !containsCanonicalClozeMarkup else { return self }

        var normalized = ""
        var cursor = startIndex
        var searchStart = startIndex
        var foundCloze = false
        while
            let opening = self[searchStart...].firstIndex(of: "["),
            let closing = self[index(after: opening)...].firstIndex(of: "]")
        {
            normalized += self[cursor..<opening]
            let hidden = self[index(after: opening)..<closing]
            let previousCharacter = opening == startIndex ? nil : self[index(before: opening)]
            let isFurigana = previousCharacter?.isKanji == true && hidden.isKanaReading
            if isFurigana {
                normalized += self[opening...closing]
            } else {
                normalized += "{{c1::" + hidden + "}}"
                foundCloze = true
            }
            cursor = index(after: closing)
            searchStart = cursor
        }
        guard foundCloze else { return self }
        normalized += self[cursor...]
        return normalized
    }

    var studyDisplayText: String {
        studyPlainText
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'", options: .caseInsensitive)
    }

    var studyPlainText: String {
        replacingOccurrences(
            of: #"<\s*br\s*/?\s*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        .replacingOccurrences(
            of: #"</\s*(p|div|li)\s*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Character {
    var isKanji: Bool {
        unicodeScalars.contains { scalar in
            (0x3400 ... 0x4DBF).contains(scalar.value)
                || (0x4E00 ... 0x9FFF).contains(scalar.value)
                || (0xF900 ... 0xFAFF).contains(scalar.value)
                || scalar.value == 0x3005
        }
    }
}

private extension Substring {
    var isKanaReading: Bool {
        !isEmpty && unicodeScalars.allSatisfy { scalar in
            (0x3040 ... 0x309F).contains(scalar.value)
                || (0x30A0 ... 0x30FF).contains(scalar.value)
                || scalar.value == 0x30FC
                || scalar.value == 0x30FB
        }
    }
}

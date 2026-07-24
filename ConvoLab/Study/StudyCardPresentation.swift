import Foundation

extension StudyCard {
    var answerAudioURL: URL? {
        answer.mediaURL(for: "answerAudio")
    }
}

struct StudyCardPresentation: Equatable, Sendable {
    struct PitchAccent: Equatable, Sendable {
        let expression: String
        let reading: String
        let morae: [String]
        let pattern: [Int]
        let patternName: String
    }

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
        let pitchAccent: PitchAccent?
    }

    let front: Face
    let back: Face
}

extension StudyCard {
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
            let restoredPlainText = answer.firstNonEmptyString(for: ["restoredText"])
                ?? cloze.restoredText
            let frontHeading = cloze.displayText.map { displayText in
                maskedRubyText(
                    displayText: displayText.studyDisplayText,
                    restoredText: restoredPlainText?.studyDisplayText,
                    restoredTextReading: answer.firstNonEmptyString(
                        for: ["restoredTextReading"]
                    )?.studyDisplayText
                )
            }

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
                    isMediaLed: promptImageURL != nil,
                    pitchAccent: nil
                ),
                back: .init(
                    heading: restoredText?.studyDisplayText,
                    supportingText: nil,
                    textBlocks: [meaning].compactMap(\.self) + notes,
                    audioURL: answerAudioURL,
                    imageURL: answerImageURL,
                    isMediaLed: false,
                    pitchAccent: answer.studyPitchAccent
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
                heading: isMediaLed ? nil : cueText.map { cueText in
                    let displayText = cueText.studyDisplayText
                    return matchingRubyText(
                        plainText: displayText,
                        candidates: [
                            prompt.firstNonEmptyString(for: ["cueReading"]),
                            answer.firstNonEmptyString(for: ["expressionReading"]),
                        ]
                    ) ?? displayText
                },
                supportingText: isMediaLed ? mediaLabel : cueMeaning?.studyDisplayText,
                textBlocks: [],
                audioURL: promptAudioURL,
                imageURL: promptImageURL,
                isMediaLed: isMediaLed,
                pitchAccent: nil
            ),
            back: .init(
                heading: answer.firstNonEmptyString(for: ["expressionReading"])?.studyDisplayText
                    ?? prompt.firstNonEmptyString(for: ["cueReading"])?.studyDisplayText
                    ?? answer.firstNonEmptyString(for: ["expression"])?.studyDisplayText,
                supportingText: nil,
                textBlocks: details,
                audioURL: answerAudioURL,
                imageURL: answerImageURL,
                isMediaLed: false,
                pitchAccent: answer.studyPitchAccent
            )
        )
    }
}

private func matchingRubyText(plainText: String, candidates: [String?]) -> String? {
    let matchText = plainText.removingStudyWhitespace
    return candidates.lazy.compactMap { $0?.studyDisplayText }.first { candidate in
        let document = StudyRubyDocument.parse(candidate, knownKanji: [])
        return document.hasRuby && document.plainText.removingStudyWhitespace == matchText
    }
}

private func maskedRubyText(
    displayText: String,
    restoredText: String?,
    restoredTextReading: String?
) -> String {
    guard
        let restoredText,
        let restoredTextReading,
        let alignedReading = alignedRubyText(
            rubyText: restoredTextReading,
            plainText: restoredText
        ),
        let markerRange = displayText.range(of: "[...]")
    else {
        return displayText
    }

    guard
        displayText.range(
            of: "[...]",
            range: markerRange.upperBound..<displayText.endIndex
        ) == nil
    else {
        // Multiple same-ordinal cloze spans are all active. Preserve the
        // already-masked display instead of reconstructing only one blank.
        return displayText
    }

    let prefix = String(displayText[..<markerRange.lowerBound])
    let suffix = String(displayText[markerRange.upperBound...])
    guard
        prefix.count + suffix.count <= restoredText.count,
        restoredText.hasPrefix(prefix),
        restoredText.hasSuffix(suffix)
    else {
        return displayText
    }

    return slicedRubyText(
        alignedReading,
        start: 0,
        end: prefix.count
    ) + "[...]" + slicedRubyText(
        alignedReading,
        start: restoredText.count - suffix.count,
        end: restoredText.count
    )
}

private func alignedRubyText(rubyText: String, plainText: String) -> String? {
    let plainCharacters = Array(plainText)
    var plainIndex = 0
    var result = ""

    func appendPlainWhitespace() {
        while plainIndex < plainCharacters.count, plainCharacters[plainIndex].isWhitespace {
            result.append(plainCharacters[plainIndex])
            plainIndex += 1
        }
    }

    for segment in StudyRubyDocument.parse(rubyText, knownKanji: []).segments {
        switch segment {
        case let .ruby(base, reading):
            appendPlainWhitespace()
            let baseCharacters = Array(base)
            guard
                plainIndex + baseCharacters.count <= plainCharacters.count,
                Array(plainCharacters[plainIndex..<(plainIndex + baseCharacters.count)])
                    == baseCharacters
            else {
                return nil
            }
            result += "\(base)[\(reading)]"
            plainIndex += baseCharacters.count
        case let .text(text):
            // The authoritative plain string supplies whitespace so cosmetic
            // spacing differences in imported ruby markup do not block alignment.
            for character in text where !character.isWhitespace {
                appendPlainWhitespace()
                guard
                    plainIndex < plainCharacters.count,
                    plainCharacters[plainIndex] == character
                else {
                    return nil
                }
                result.append(character)
                plainIndex += 1
            }
        }
    }

    appendPlainWhitespace()
    return plainIndex == plainCharacters.count ? result : nil
}

private func slicedRubyText(_ value: String, start: Int, end: Int) -> String {
    var offset = 0
    var result = ""

    for segment in StudyRubyDocument.parse(value, knownKanji: []).segments {
        let plain = segment.baseText
        let segmentStart = offset
        let segmentEnd = offset + plain.count
        offset = segmentEnd

        let sliceStart = max(start, segmentStart)
        let sliceEnd = min(end, segmentEnd)
        guard sliceStart < sliceEnd else { continue }

        let characters = Array(plain)
        let visible = String(
            characters[(sliceStart - segmentStart)..<(sliceEnd - segmentStart)]
        )
        if
            case let .ruby(_, reading) = segment,
            sliceStart == segmentStart,
            sliceEnd == segmentEnd
        {
            result += "\(visible)[\(reading)]"
        } else {
            result += visible
        }
    }

    return result
}

private extension JSONValue {
    var studyPitchAccent: StudyCardPresentation.PitchAccent? {
        guard
            let value = self["pitchAccent"],
            value["status"]?.stringValue == "resolved",
            let expression = value["expression"]?.stringValue,
            let reading = value["reading"]?.stringValue,
            let patternName = value["patternName"]?.stringValue,
            case let .array(moraValues) = value["morae"],
            case let .array(patternValues) = value["pattern"]
        else {
            return nil
        }
        let morae = moraValues.compactMap(\.stringValue)
        let pattern = patternValues.compactMap { item -> Int? in
            guard case let .number(value) = item, value == 0 || value == 1 else {
                return nil
            }
            return Int(value)
        }
        guard
            !expression.isEmpty,
            !reading.isEmpty,
            !morae.isEmpty,
            morae.count == moraValues.count,
            pattern.count == patternValues.count,
            pattern.count == morae.count
        else {
            return nil
        }
        return .init(
            expression: expression,
            reading: reading,
            morae: morae,
            pattern: pattern,
            patternName: patternName
        )
    }

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
    var removingStudyWhitespace: String {
        filter { !$0.isWhitespace }
    }

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

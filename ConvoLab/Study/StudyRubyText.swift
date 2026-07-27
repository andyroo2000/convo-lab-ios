import CoreText
import SwiftUI
import UIKit

private final class StudyRubyUITextView: UITextView {
    override func copy(_ sender: Any?) {
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else {
            super.copy(sender)
            return
        }

        let selectedText = (attributedText.string as NSString)
            .substring(with: selectedRange)
            .removingStudyRubyLayoutControls
        UIPasteboard.general.string = selectedText
    }

    override func text(in range: UITextRange) -> String? {
        super.text(in: range)?.removingStudyRubyLayoutControls
    }
}

struct StudyRubyDocument: Equatable {
    private static let annotationExpression = try? NSRegularExpression(
        pattern:
            #"([\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}々\x{3040}-\x{309F}\x{30A0}-\x{30FF}]+)(?:\[([^\]]+)\]|\(([^)]+)\))"#
    )

    enum Segment: Equatable {
        case text(String)
        case ruby(base: String, reading: String)

        var baseText: String {
            switch self {
            case let .text(text): text
            case let .ruby(base, _): base
            }
        }
    }

    let segments: [Segment]

    var plainText: String {
        segments.map(\.baseText).joined()
    }

    var hasRuby: Bool {
        segments.contains {
            if case .ruby = $0 { true } else { false }
        }
    }

    static func parse(_ value: String, knownKanji: Set<Character>) -> StudyRubyDocument {
        guard let expression = annotationExpression else {
            return StudyRubyDocument(segments: [.text(value)])
        }

        let fullRange = NSRange(value.startIndex..., in: value)
        var segments: [Segment] = []
        var cursor = value.startIndex

        for match in expression.matches(in: value, range: fullRange) {
            guard
                let matchRange = Range(match.range(at: 0), in: value),
                let baseRange = Range(match.range(at: 1), in: value)
            else {
                continue
            }
            let bracketReading = Range(match.range(at: 2), in: value).map { String(value[$0]) }
            let parentheticalReading = Range(match.range(at: 3), in: value).map {
                String(value[$0])
            }
            let reading = bracketReading ?? parentheticalReading ?? ""
            let base = String(value[baseRange])

            if !base.containsKanjiOrIterationMark || !reading.isKanaReading {
                continue
            }

            appendText(String(value[cursor..<matchRange.lowerBound]), to: &segments)
            let normalized = normalize(base: base, reading: reading)
            appendText(normalized.prefix, to: &segments)

            let annotatedKanji = normalized.kanjiPart.filter(\.isKanji)
            let hideReading = !annotatedKanji.isEmpty
                && annotatedKanji.allSatisfy { knownKanji.contains($0) }
            if hideReading {
                appendText(normalized.kanjiPart, to: &segments)
            } else {
                segments.append(.ruby(
                    base: normalized.kanjiPart,
                    reading: normalized.reading
                ))
            }
            appendText(normalized.suffix, to: &segments)
            cursor = matchRange.upperBound
        }

        appendText(String(value[cursor...]), to: &segments)
        return StudyRubyDocument(segments: segments.isEmpty ? [.text(value)] : segments)
    }

    private static func appendText(_ text: String, to segments: inout [Segment]) {
        guard !text.isEmpty else { return }
        if case let .text(previous)? = segments.last {
            segments[segments.count - 1] = .text(previous + text)
        } else {
            segments.append(.text(text))
        }
    }

    private static func normalize(
        base: String,
        reading: String
    ) -> (prefix: String, kanjiPart: String, suffix: String, reading: String) {
        let characters = Array(base)
        var kanjiStart = 0
        while kanjiStart < characters.count, characters[kanjiStart].isKana {
            kanjiStart += 1
        }

        var kanjiEnd = characters.count
        while kanjiEnd > kanjiStart, characters[kanjiEnd - 1].isKana {
            kanjiEnd -= 1
        }

        let candidate = String(characters[kanjiStart..<kanjiEnd])
        guard kanjiStart < kanjiEnd, candidate.containsKanjiOrIterationMark else {
            return ("", base, "", reading.removingWhitespace)
        }

        let prefix = String(characters[..<kanjiStart])
        let suffix = String(characters[kanjiEnd...])
        let cleanReading = reading.removingWhitespace
        var adjustedReading = cleanReading
        if !prefix.isEmpty, adjustedReading.hasPrefix(prefix) {
            adjustedReading.removeFirst(prefix.count)
        }
        if !suffix.isEmpty, adjustedReading.hasSuffix(suffix) {
            adjustedReading.removeLast(suffix.count)
        }

        return (
            prefix,
            candidate,
            suffix,
            adjustedReading.isEmpty ? cleanReading : adjustedReading
        )
    }
}

struct StudyRubyText: UIViewRepresentable {
    let text: String
    let knownKanji: Set<Character>
    let pointSize: CGFloat
    let weight: UIFont.Weight
    let color: UIColor
    let alignment: NSTextAlignment

    init(
        _ text: String,
        knownKanji: Set<Character>,
        pointSize: CGFloat,
        weight: UIFont.Weight = .regular,
        color: UIColor = .label,
        alignment: NSTextAlignment = .center
    ) {
        self.text = text
        self.knownKanji = knownKanji
        self.pointSize = pointSize
        self.weight = weight
        self.color = color
        self.alignment = alignment
    }

    func makeUIView(context: Context) -> UITextView {
        let view = StudyRubyUITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let document = StudyRubyDocument.parse(text, knownKanji: knownKanji)
        let scaledPointSize = UIFontMetrics.default.scaledValue(for: pointSize)
        view.textContainerInset = UIEdgeInsets(
            top: document.hasRuby ? scaledPointSize * 0.52 : 0,
            left: 0,
            bottom: document.hasRuby ? scaledPointSize * 0.08 : 0,
            right: 0
        )
        view.attributedText = document.attributedString(
            pointSize: pointSize,
            weight: weight,
            color: color,
            alignment: alignment
        )
        view.textAlignment = alignment
        view.accessibilityLabel = document.plainText
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(size.height))
    }
}

extension StudyRubyDocument {
    func attributedString(
        pointSize: CGFloat,
        weight: UIFont.Weight,
        color: UIColor,
        alignment: NSTextAlignment
    ) -> NSAttributedString {
        let baseFont = UIFont.systemFont(ofSize: pointSize, weight: weight)
        let roundedDescriptor = baseFont.fontDescriptor.withDesign(.rounded)
            ?? baseFont.fontDescriptor
        let font = UIFontMetrics.default.scaledFont(
            for: UIFont(descriptor: roundedDescriptor, size: pointSize)
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        if hasRuby {
            paragraph.lineSpacing = font.lineHeight * 0.4
        }
        let output = NSMutableAttributedString()
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]

        for segment in segments {
            switch segment {
            case let .text(text):
                output.append(NSAttributedString(string: text, attributes: baseAttributes))
            case let .ruby(base, reading):
                let annotated = NSMutableAttributedString(
                    // Japanese line breaking normally permits a wrap between
                    // any two ideographs. Keep a multi-character ruby base
                    // together so Core Text never splits the base across lines
                    // and silently drops its reading.
                    string: base.joinedWithWordJoiners,
                    attributes: baseAttributes
                )
                let annotation = CTRubyAnnotationCreateWithAttributes(
                    .auto,
                    .auto,
                    .before,
                    reading as CFString,
                    [
                        kCTRubyAnnotationSizeFactorAttributeName: NSNumber(value: 0.42),
                        kCTForegroundColorAttributeName: UIColor.secondaryLabel.cgColor,
                    ] as CFDictionary
                )
                annotated.addAttribute(
                    NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
                    value: annotation,
                    range: NSRange(location: 0, length: annotated.length)
                )
                output.append(annotated)
            }
        }
        return output
    }
}

extension String {
    var removingStudyRubyLayoutControls: String {
        replacingOccurrences(of: "\u{2060}", with: "")
    }
}

private extension Character {
    var isKana: Bool {
        unicodeScalars.allSatisfy { scalar in
            (0x3040 ... 0x309F).contains(scalar.value)
                || (0x30A0 ... 0x30FF).contains(scalar.value)
                || scalar.value == 0x30FC
                || scalar.value == 0x30FB
        }
    }

    var isKanji: Bool {
        unicodeScalars.contains { scalar in
            (0x3400 ... 0x4DBF).contains(scalar.value)
                || (0x4E00 ... 0x9FFF).contains(scalar.value)
                || (0xF900 ... 0xFAFF).contains(scalar.value)
        }
    }
}

private extension String {
    var joinedWithWordJoiners: String {
        guard count > 1 else { return self }
        return map(String.init).joined(separator: "\u{2060}")
    }

    var containsKanjiOrIterationMark: Bool {
        contains { $0.isKanji || $0 == "々" }
    }

    var isKanaReading: Bool {
        let compact = removingWhitespace
        return !compact.isEmpty && compact.allSatisfy(\.isKana)
    }

    var removingWhitespace: String {
        filter { !$0.isWhitespace }
    }
}

import UIKit

/// TextKit centers differing font descenders inside fixed-height lines. Keep one baseline instead.
final class JournalExplanationLayout: NSObject, NSTextLayoutManagerDelegate {
    private let ruby = StudyRubyLineBreakDelegate()
    private var baseline: CGFloat = 0

    func update(_ text: NSAttributedString, font: UIFont) {
        ruby.updateRubyRanges(in: text)
        guard text.length > 0, let paragraph = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else { return }
        baseline = paragraph.minimumLineHeight + font.descender
    }

    func textLayoutManager(_ manager: NSTextLayoutManager, shouldBreakLineBefore location: any NSTextLocation, hyphenating: Bool) -> Bool {
        ruby.textLayoutManager(manager, shouldBreakLineBefore: location, hyphenating: hyphenating)
    }

    func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in element: NSTextElement) -> NSTextLayoutFragment {
        JournalUniformParagraph(textElement: element, range: nil, baseline: baseline)
    }
}

nonisolated private final class JournalUniformParagraph: NSTextLayoutFragment {
    private let baseline: CGFloat
    init(textElement: NSTextElement, range: NSTextRange?, baseline: CGFloat) {
        self.baseline = baseline
        super.init(textElement: textElement, range: range)
    }
    required init?(coder: NSCoder) { nil }

    override var textLineFragments: [NSTextLineFragment] {
        super.textLineFragments.map { JournalUniformLine($0, baseline: baseline) }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        for line in textLineFragments {
            line.draw(at: CGPoint(x: point.x + line.typographicBounds.minX,
                                 y: point.y + line.typographicBounds.minY), in: context)
        }
    }
}

nonisolated private final class JournalUniformLine: NSTextLineFragment {
    private let source: NSTextLineFragment
    private let baseline: CGFloat
    init(_ source: NSTextLineFragment, baseline: CGFloat) {
        self.source = source
        self.baseline = baseline
        super.init(attributedString: source.attributedString, range: source.characterRange)
    }
    required init?(coder: NSCoder) { nil }
    override var typographicBounds: CGRect { source.typographicBounds }
    override var glyphOrigin: CGPoint { CGPoint(x: source.glyphOrigin.x, y: baseline) }
    override func draw(at point: CGPoint, in context: CGContext) {
        source.draw(at: CGPoint(x: point.x, y: point.y + baseline - source.glyphOrigin.y), in: context)
    }
    override func locationForCharacter(at index: Int) -> CGPoint {
        let point = source.locationForCharacter(at: index)
        return CGPoint(x: point.x, y: point.y + baseline - source.glyphOrigin.y)
    }
    override func characterIndex(for point: CGPoint) -> Int {
        source.characterIndex(for: CGPoint(x: point.x, y: point.y - baseline + source.glyphOrigin.y))
    }
    override func fractionOfDistanceThroughGlyph(for point: CGPoint) -> CGFloat {
        source.fractionOfDistanceThroughGlyph(for: CGPoint(x: point.x, y: point.y - baseline + source.glyphOrigin.y))
    }
}

import UIKit

/// Draw only behind the glyph row, leaving furigana and interline spacing clear.
final class JournalHighlightTextView: UITextView {
    var highlights: [(range: NSRange, kind: JournalSegment.Kind)] = [] {
        didSet { setNeedsLayout() }
    }
    private var highlightLayers: [CALayer] = []

    init() {
        // Use the designated initializer so Swift storage exists before UIKit lays out.
        super.init(frame: .zero, textContainer: nil)
        textLayoutManager?.usesFontLeading = false
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayers.forEach { $0.removeFromSuperlayer() }
        highlightLayers = []
        for highlight in highlights where highlight.kind.isHighlighted {
            drawHighlight(highlight.range, optional: highlight.kind == .optional)
        }
        CATransaction.commit()
    }

    private func drawHighlight(_ range: NSRange, optional: Bool) {
        guard range.location >= 0, range.length > 0,
              NSMaxRange(range) <= attributedText.length,
              let manager = textLayoutManager,
              let content = manager.textContentManager,
              let startLocation = content.location(content.documentRange.location, offsetBy: range.location) else { return }
        manager.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let lineRange = NSRange(location: offset + line.characterRange.location, length: line.characterRange.length)
                let overlap = NSIntersectionRange(range, lineRange)
                guard overlap.length > 0 else { continue }
                let baseline = JournalRubyTypography.glyphBaseline(in: self, fragment: fragment, line: line, at: overlap.location)
                self.drawHighlightLine(overlap, baseline: baseline, optional: optional)
            }
            let fragmentEnd = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.endLocation)
            return fragmentEnd < NSMaxRange(range)
        }
    }

    private func drawHighlightLine(_ range: NSRange, baseline: CGFloat, optional: Bool) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        let font = attributedText.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
            ?? UIFont.systemFont(ofSize: 20)
        for selection in selectionRects(for: textRange) where selection.rect.width > 0 {
            var rect = selection.rect
            // Selection bounds include line spacing. Anchor to the actual glyph baseline
            // so the fill covers the base text without extending into the furigana row.
            // Two points of padding above and below soften the highlight edges.
            rect.origin.y = baseline - font.ascender - 2
            rect.size.height = font.ascender - font.descender + 4
            rect = rect.insetBy(dx: -1, dy: 0).intersection(bounds)
            if !rect.isEmpty { addHighlight(rect, optional: optional) }
        }
    }

    private func addHighlight(_ rect: CGRect, optional: Bool) {
        let fill = optional ? JournalPopoverStyle.optionalFill : JournalPopoverStyle.correctionFill
        let stroke = optional ? JournalPopoverStyle.optionalLine : JournalPopoverStyle.correctionLine
        let background = CAShapeLayer()
        background.path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath
        background.fillColor = fill.resolvedColor(with: traitCollection).cgColor
        let underline = CAShapeLayer()
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY))
        underline.path = path.cgPath
        underline.strokeColor = stroke.resolvedColor(with: traitCollection).cgColor
        underline.lineWidth = 1
        underline.lineDashPattern = optional ? [3, 2] : nil
        for decoration in [background, underline] {
            layer.insertSublayer(decoration, at: UInt32(highlightLayers.count))
            highlightLayers.append(decoration)
        }
    }
}

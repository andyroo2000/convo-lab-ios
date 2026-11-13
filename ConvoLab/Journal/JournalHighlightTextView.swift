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
        guard range.length > 0, NSMaxRange(range) <= attributedText.length,
              let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        let font = attributedText.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
        let rowHeight = (font?.lineHeight ?? 24) + 4
        for selection in selectionRects(for: textRange) where selection.rect.width > 0 {
            var rect = selection.rect
            let height = min(rect.height, rowHeight)
            // Selection rectangles include the preceding interline space on wrapped rows.
            rect.origin.y = rect.maxY - height
            rect.size.height = height
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

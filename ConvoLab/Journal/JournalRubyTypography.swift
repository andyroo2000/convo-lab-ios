import CoreText
import UIKit

/// Keep readings close to their kanji without changing notebook baselines.
enum JournalRubyTypography {
    @discardableResult
    static func compact(_ text: NSMutableAttributedString, onPaper: Bool = false, useTextColor: Bool = false) -> CGFloat {
        var inset: CGFloat = 0
        let key = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        text.enumerateAttribute(key, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let value, let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont else { return }
            let annotation = value as! CTRubyAnnotation
            guard let reading = CTRubyAnnotationGetTextForPosition(annotation, .before) else { return }
            if onPaper {
                // Klee One's tall line metrics leave more space above its kanji than Hiragino's.
                let extraHeight = max(0, font.lineHeight - font.pointSize)
                inset = max(inset, font.pointSize * 0.035 + extraHeight * 0.7)
            }
            let textColor = text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor ?? .secondaryLabel
            let closer = CTRubyAnnotationCreateWithAttributes(.auto, .auto, .before, reading, [
                kCTRubyAnnotationSizeFactorAttributeName: 0.42,
                kCTBaselineOffsetAttributeName: -font.pointSize * 0.10,
                kCTForegroundColorAttributeName: (useTextColor ? textColor : UIColor.secondaryLabel).cgColor
            ] as CFDictionary)
            text.addAttribute(key, value: closer, range: range)
        }
        // TextKit positions ruby independently of the base glyphs. Raise the base text and
        // inset the whole line equally so only the readings move relative to the paper rules.
        if inset > 0 {
            text.addAttribute(.baselineOffset, value: inset, range: NSRange(location: 0, length: text.length))
        }
        return inset
    }

    static func glyphBaseline(in view: UITextView, fragment: NSTextLayoutFragment, line: NSTextLineFragment, at index: Int) -> CGFloat {
        let baseline = view.textContainerInset.top + fragment.layoutFragmentFrame.minY
            + line.typographicBounds.minY + line.glyphOrigin.y
        guard let text = view.attributedText, (0..<text.length).contains(index) else { return baseline }
        let offset = text.attribute(.baselineOffset, at: index, effectiveRange: nil) as? CGFloat ?? 0
        return baseline - offset
    }
}

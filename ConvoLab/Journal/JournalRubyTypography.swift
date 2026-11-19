import CoreText
import UIKit

/// Keep readings close to their kanji without changing notebook baselines.
enum JournalRubyTypography {
    static func compact(_ text: NSMutableAttributedString) {
        let key = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        text.enumerateAttribute(key, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let value, let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont else { return }
            let annotation = value as! CTRubyAnnotation
            guard let reading = CTRubyAnnotationGetTextForPosition(annotation, .before) else { return }
            let closer = CTRubyAnnotationCreateWithAttributes(.auto, .auto, .before, reading, [
                kCTRubyAnnotationSizeFactorAttributeName: 0.42,
                kCTBaselineOffsetAttributeName: -font.pointSize * 0.10,
                kCTForegroundColorAttributeName: UIColor.secondaryLabel.cgColor
            ] as CFDictionary)
            text.addAttribute(key, value: closer, range: range)
        }
    }
}

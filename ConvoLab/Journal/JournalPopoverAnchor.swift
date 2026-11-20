import UIKit

enum JournalPopoverAnchor {
    static func glyphRect(selection: CGRect, range: NSRange, in view: UITextView, font: UIFont) -> CGRect {
        guard let manager = view.textLayoutManager, let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location) else { return selection }
        var anchor = selection
        manager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            guard let line = fragment.textLineFragments.first(where: {
                NSLocationInRange(range.location, NSRange(location: offset + $0.characterRange.location, length: $0.characterRange.length))
            }) else { return false }
            let baseline = JournalRubyTypography.glyphBaseline(in: view, fragment: fragment, line: line, at: range.location)
            anchor.origin.y = baseline - font.ascender - 2
            anchor.size.height = font.ascender - font.descender + 4
            return false
        }
        return anchor
    }
}

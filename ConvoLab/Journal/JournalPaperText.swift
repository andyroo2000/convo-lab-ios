import SwiftUI
import UIKit

private struct JournalOnPaperKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var journalOnPaper: Bool {
        get { self[JournalOnPaperKey.self] }
        set { self[JournalOnPaperKey.self] = newValue }
    }
}

enum JournalPaperText {
    static func align(_ text: NSMutableAttributedString, font: UIFont) {
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            // One shared pitch for ruled paper, independent of font metrics or furigana.
            paragraph.minimumLineHeight = font.pointSize * 2.7
            paragraph.maximumLineHeight = font.pointSize * 2.7
            paragraph.lineSpacing = 0
            text.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
    }
}

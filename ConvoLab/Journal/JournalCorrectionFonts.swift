import UIKit

enum JournalCorrectionFonts {
    static let latinScale: CGFloat = 0.8
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}々〆ー]+"#)
    private static let punctuation = try! NSRegularExpression(pattern: #"[\u3000-\u303F\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF60]+"#)

    static func japanese(size: CGFloat) -> UIFont {
        UIFont(name: "HiraMinProN-W6", size: size) ?? .systemFont(ofSize: size, weight: .bold)
    }

    static func words(in text: NSAttributedString) -> [NSTextCheckingResult] {
        wordPattern.matches(in: text.string, range: NSRange(location: 0, length: text.length))
    }

    static func applyJapanese(to text: NSMutableAttributedString, size: CGFloat) {
        let font = japanese(size: size)
        let marks = punctuation.matches(in: text.string, range: NSRange(location: 0, length: text.length))
        for match in words(in: text) + marks {
            text.addAttribute(.font, value: font, range: match.range)
        }
    }
}

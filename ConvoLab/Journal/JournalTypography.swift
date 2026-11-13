import SwiftUI
import UIKit

struct JournalTypography: Equatable {
    static let fontKey = "journal.typography.font"
    static let sizeKey = "journal.typography.size"
    var serif = false
    var size: Double = 20

    init(font: String = "sans", size: Double = 20) {
        serif = font == "serif"
        self.size = size.isFinite ? min(30, max(16, size.rounded())) : 20
    }

    private var fontName: String { serif ? "HiraMinProN-W3" : "HiraginoSans-W3" }
    var unscaledFont: UIFont { UIFont(name: fontName, size: size) ?? UIFont.systemFont(ofSize: size) }
    var uiFont: UIFont { UIFontMetrics.default.scaledFont(for: unscaledFont) }
    var font: Font { .custom(fontName, size: size, relativeTo: .body) }
}

private struct JournalTypographyKey: EnvironmentKey {
    static let defaultValue = JournalTypography()
}
extension EnvironmentValues {
    var journalTypography: JournalTypography {
        get { self[JournalTypographyKey.self] }
        set { self[JournalTypographyKey.self] = newValue }
    }
}

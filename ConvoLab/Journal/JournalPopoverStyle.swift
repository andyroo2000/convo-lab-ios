import SwiftUI
import UIKit

enum JournalPopoverStyle {
    static let surface = adaptive(light: 0xfffefa, dark: 0x2a3338)
    static let ink = adaptive(light: 0x173b56, dark: 0xe2e9ee)
    static let muted = adaptive(light: 0x65727b, dark: 0xabb8c0)
    static let line = adaptive(light: 0xe5e7e5, dark: 0x455055)
    static let accent = adaptive(light: 0x347b9b, dark: 0x80c0dd)
    static let onAccent = adaptive(light: 0xffffff, dark: 0x172d3d)

    private static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
    }
}

struct JournalSuggestionButtonStyle: ButtonStyle {
    let applied: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color(uiColor: applied ? JournalPopoverStyle.ink : JournalPopoverStyle.onAccent))
            .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 44)
            .background(Color(uiColor: applied ? JournalPopoverStyle.surface : JournalPopoverStyle.accent))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(uiColor: applied ? JournalPopoverStyle.line : JournalPopoverStyle.accent)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

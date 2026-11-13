import SwiftUI

struct JournalToolbarButtonStyle: ButtonStyle {
    let outlined: Bool
    private let blue = Color(red: 103 / 255, green: 149 / 255, blue: 238 / 255)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 23)).foregroundStyle(blue)
            .frame(width: outlined ? 52 : 44, height: 44)
            .background(blue.opacity(configuration.isPressed ? 0.15 : outlined ? 0 : 0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(blue.opacity(outlined ? 0.6 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

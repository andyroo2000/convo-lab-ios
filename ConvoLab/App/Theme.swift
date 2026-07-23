import SwiftUI

enum ConvoLabTheme {
    static let navy = Color(red: 17 / 255, green: 51 / 255, blue: 92 / 255)
    static let cyan = Color(red: 26 / 255, green: 178 / 255, blue: 209 / 255)
    static let cream = Color(red: 251 / 255, green: 245 / 255, blue: 224 / 255)
    static let coral = Color(red: 238 / 255, green: 104 / 255, blue: 90 / 255)
}

struct PaperBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(ConvoLabTheme.cream.ignoresSafeArea())
            .tint(ConvoLabTheme.navy)
    }
}

extension View {
    func paperBackground() -> some View {
        modifier(PaperBackground())
    }
}


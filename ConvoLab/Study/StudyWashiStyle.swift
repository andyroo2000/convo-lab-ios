import SwiftUI
import UIKit

enum StudyWashiStyle {
    static var noteFont: UIFont {
        let base = UIFont(name: "CrimsonPro-Regular", size: 17) ?? .systemFont(ofSize: 17)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) ?? base.fontDescriptor
        return UIFontMetrics.default.scaledFont(for: UIFont(descriptor: descriptor, size: 17))
    }

    static let desk = Color(red: 243 / 255, green: 237 / 255, blue: 223 / 255)
    static let paper = Color(red: 236 / 255, green: 227 / 255, blue: 203 / 255)
    static let green = Color(red: 120 / 255, green: 164 / 255, blue: 106 / 255)
    static let good = Color(red: 120 / 255, green: 168 / 255, blue: 85 / 255)
    static let muted = Color(red: 105 / 255, green: 108 / 255, blue: 97 / 255)
    static let line = Color(red: 204 / 255, green: 199 / 255, blue: 182 / 255)
    static let noteRule = Color(red: 174 / 255, green: 184 / 255, blue: 146 / 255)
}

struct StudyWashiCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .padding(.horizontal, 25)
                    .padding(.vertical, 30)
                    .frame(maxWidth: 720)
                    .background {
                        StudyWashiStyle.paper
                            .overlay {
                                Image("StudyWashiFibers")
                                    .resizable(resizingMode: .tile)
                                    .opacity(0.5)
                                    .accessibilityHidden(true)
                            }
                    }
                    .clipShape(.rect(cornerRadius: 1))
                    .shadow(color: .brown.opacity(0.14), radius: 3, x: 1, y: 2)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .environment(\.colorScheme, .light)
    }
}

struct StudyWashiAudioButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(ConvoLabTheme.cream)
            .frame(width: 52, height: 52)
            .background(StudyWashiStyle.green, in: .rect(cornerRadius: 9))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct StudyWashiGradeButtonStyle: ButtonStyle {
    let color: Color
    let isGood: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("CrimsonPro-Regular", size: 20, relativeTo: .body))
            .foregroundStyle(isGood ? Color(red: 19 / 255, green: 44 / 255, blue: 12 / 255) : color)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(isGood ? StudyWashiStyle.good : StudyWashiStyle.paper, in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isGood ? .clear : StudyWashiStyle.line, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct StudyWashiNoteStyle: ViewModifier {
    let isNote: Bool

    func body(content: Content) -> some View {
        content
            .padding(.leading, isNote ? 11 : 0)
            .overlay(alignment: .leading) {
                if isNote {
                    Rectangle().fill(StudyWashiStyle.noteRule).frame(width: 2)
                }
            }
    }
}

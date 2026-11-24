import SwiftUI
import UIKit

enum StudyWashiStyle {
    static let actionFont = Font.custom("CrimsonPro-Regular", size: 18, relativeTo: .body)

    static var noteFont: UIFont {
        let base = UIFont(name: "CrimsonPro-Regular", size: 17) ?? .systemFont(ofSize: 17)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) ?? base.fontDescriptor
        return UIFontMetrics.default.scaledFont(for: UIFont(descriptor: descriptor, size: 17))
    }

    static let desk = Color(red: 243 / 255, green: 237 / 255, blue: 223 / 255)
    static let paper = desk
    static let green = Color(red: 106 / 255, green: 148 / 255, blue: 92 / 255)
    static let good = Color(red: 120 / 255, green: 168 / 255, blue: 85 / 255)
    static let muted = Color(red: 92 / 255, green: 96 / 255, blue: 85 / 255)
    static let line = Color(red: 204 / 255, green: 199 / 255, blue: 182 / 255)
    static let noteRule = Color(red: 174 / 255, green: 184 / 255, blue: 146 / 255)
}

struct StudyWashiCard<Content: View>: View {
    var centered = false
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .padding(.horizontal, 9)
                    .padding(.vertical, 13)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height,
                           alignment: centered ? .center : .top)
            }
        }
        .environment(\.colorScheme, .light)
    }
}

struct StudyWashiAudioButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var playing = false
    @ScaledMetric(relativeTo: .body) private var buttonSize = 60

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(ConvoLabTheme.cream)
            .frame(width: buttonSize, height: buttonSize)
            .background(playing ? Color(red: 72 / 255, green: 116 / 255, blue: 67 / 255) : StudyWashiStyle.green,
                        in: .rect(cornerRadius: 13))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct StudyWashiBackground: View {
    var body: some View {
        StudyWashiStyle.desk.overlay {
            Image("StudyWashiFibers")
                .resizable(resizingMode: .tile)
                .opacity(0.18)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }
}

struct StudyRevealButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StudyWashiStyle.actionFont.weight(.semibold))
            .foregroundStyle(DrillPaper.ink)
            .padding(.horizontal, 25)
            .padding(.vertical, 9)
            .frame(minWidth: 150, minHeight: 48)
            .background(Color(red: 0.898, green: 0.933, blue: 0.984), in: .capsule)
            .overlay { Capsule().strokeBorder(Color(red: 0.44, green: 0.52, blue: 0.63)) }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct StudyWashiGradeButtonStyle: ButtonStyle {
    let color: Color
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StudyWashiStyle.actionFont)
            .foregroundStyle(selected ? .white : Color(red: 0.10, green: 0.15, blue: 0.13))
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(selected ? ConvoLabTheme.navy : color, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.rect)
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

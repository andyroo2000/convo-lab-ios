import SwiftUI
import UIKit

enum StudyWashiStyle {
    static let actionFont = Font.custom("CrimsonPro-Regular", size: 18, relativeTo: .body)

    static var noteFont: UIFont {
        let base = UIFont(name: "CrimsonPro-Regular", size: 17) ?? .systemFont(ofSize: 17)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) ?? base.fontDescriptor
        return UIFontMetrics.default.scaledFont(for: UIFont(descriptor: descriptor, size: 17))
    }

    static let ink = JournalBrandStyle.ink
    static let secondaryInk = ink.opacity(0.72)
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

extension View {
    func studySpeakerTile(size: CGFloat, playing: Bool) -> some View {
        let glyphSize = size * 44 / 60
        let fill = playing ? Color(red: 72 / 255, green: 116 / 255, blue: 67 / 255) : StudyWashiStyle.green
        return self
            .frame(width: glyphSize, height: glyphSize)
            .foregroundStyle(ConvoLabTheme.cream)
            .frame(width: size, height: size)
            .background(fill, in: .rect(cornerRadius: size * 13 / 60))
    }
}

struct StudyWashiAudioButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var playing = false
    @ScaledMetric(relativeTo: .body) private var buttonSize = 60

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .studySpeakerTile(size: buttonSize, playing: playing)
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
            .foregroundStyle(Color(red: 1, green: 0.984, blue: 0.929))
            .padding(.horizontal, 29)
            .padding(.vertical, 9)
            .frame(minWidth: 150, minHeight: 48)
            .background(Color(red: 0.243, green: 0.459, blue: 0.275), in: .capsule)
            .overlay { Capsule().strokeBorder(Color(red: 0.224, green: 0.431, blue: 0.251)) }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct StudyWashiGradeButtonStyle: ButtonStyle {
    let rating: ReviewRating

    private var colors: (fill: Color, selected: Color) {
        switch rating {
        case .again: (.init(red: 0.941, green: 0.698, blue: 0.655), .init(red: 0.549, green: 0.239, blue: 0.204))
        case .hard: (.init(red: 0.914, green: 0.765, blue: 0.569), .init(red: 0.471, green: 0.341, blue: 0.114))
        case .good: (.init(red: 0.647, green: 0.824, blue: 0.812), .init(red: 0.224, green: 0.392, blue: 0.365))
        case .easy: (.init(red: 0.725, green: 0.827, blue: 0.647), .init(red: 0.267, green: 0.4, blue: 0.22))
        }
    }

    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StudyWashiStyle.actionFont.weight(.semibold))
            .foregroundStyle(selected ? .white : StudyWashiStyle.ink)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(selected ? colors.selected : colors.fill, in: .capsule)
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(colors.selected, Color.white)
                        .font(.caption.bold())
                        .offset(x: 2, y: -5)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
            .opacity(isEnabled || selected ? (configuration.isPressed ? 0.8 : 1) : 0.55)
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

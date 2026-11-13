import SwiftUI

struct JournalAppearance: View {
    @AppStorage(JournalTypography.fontKey) private var font = "sans"
    @AppStorage(JournalTypography.sizeKey) private var size = 20.0
    @Environment(\.dismiss) private var dismiss
    private var typography: JournalTypography { JournalTypography(font: font, size: size) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Journal appearance").font(.headline)
                    Spacer()
                    Button("Done") { dismiss() }.frame(minHeight: 44)
                }
                Text("Font").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    fontCard("Sans-serif", value: "sans")
                    fontCard("Serif", value: "serif")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Base font size")
                        Spacer()
                        Text("\(Int(typography.size)) pt").monospacedDigit()
                    }.font(.subheadline)
                    Slider(value: Binding(get: { typography.size }, set: { size = $0 }), in: 16...30, step: 1)
                        .accessibilityLabel("Font size")
                        .accessibilityValue("\(Int(typography.size)) points")
                }
                Text("Scales with your system text size.").font(.footnote).foregroundStyle(.secondary)
            }.padding(24)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func fontCard(_ title: String, value: String) -> some View {
        let selected = (typography.serif ? "serif" : "sans") == value
        return Button { font = value } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Aa あ").font(JournalTypography(font: value, size: 28).font)
                    Spacer(minLength: 0)
                }.accessibilityHidden(true)
                HStack {
                    Text(title).font(.subheadline)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.accentColor.opacity(0.08) : Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : Color(.separator)))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct JournalBodyFont: ViewModifier {
    @Environment(\.journalTypography) private var typography
    func body(content: Content) -> some View { content.font(typography.font) }
}

struct JournalRubyText: View {
    @ScaledMetric(relativeTo: .body) private var textScale = 1.0
    let text: String
    let knownKanji: Set<Character>
    @Environment(\.journalTypography) private var typography

    var body: some View {
        StudyRubyText(text, knownKanji: knownKanji, pointSize: typography.size, alignment: .left, extraLineSpacing: 10, font: typography.unscaledFont.withSize(typography.size * textScale))
    }
}

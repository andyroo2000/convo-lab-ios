import SwiftUI

struct JournalAppearance: View {
    @AppStorage(JournalTypography.fontKey) private var font = JournalTypography.defaultFont
    @AppStorage(JournalTypography.sizeKey) private var size = 20.0
    private var typography: JournalTypography { JournalTypography(font: font, size: size) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("今日はいい一日でした。\nToday was a good day.")
                    .font(typography.font)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("JournalAppearancePreview")
                VStack(spacing: 12) {
                    fontCard("Klee One", value: "klee")
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

            }.padding(24)
        }
        .tint(JournalToolbarButtonStyle.blue)
        .presentationDetents([.height(560), .large])
        .presentationDragIndicator(.visible)
    }

    private func fontCard(_ title: String, value: String) -> some View {
        let selected = typography.selection == value
        return Button { font = value } label: {
            HStack(spacing: 16) {
                Text("Aa あ").font(JournalTypography(font: value, size: 28).font).accessibilityHidden(true)
                Text(title).font(.subheadline)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? JournalToolbarButtonStyle.blue.opacity(0.08) : Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? JournalToolbarButtonStyle.blue : Color(.separator)))
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

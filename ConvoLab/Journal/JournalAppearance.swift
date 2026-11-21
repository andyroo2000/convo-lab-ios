import SwiftUI

struct JournalAppearance: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(JournalTypography.fontKey) private var font = JournalTypography.defaultFont
    @AppStorage(JournalTypography.sizeKey) private var size = 20.0
    private var typography: JournalTypography { JournalTypography(font: font, size: size) }

    var body: some View {
        JournalDialogSheet {
            JournalDialogHeading(title: "Journal appearance", closeLabel: "Close appearance") { dismiss() }
            Text("今日はいい一日でした。")
                .font(typography.font)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.white, in: .rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(JournalDialogStyle.border) }
                .accessibilityIdentifier("JournalAppearancePreview")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                fontCard("Klee One", value: "klee")
                fontCard("Sans-serif", value: "sans")
                fontCard("Serif", value: "serif")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Font size")
                    Spacer()
                    Text("\(Int(typography.size)) pt").monospacedDigit()
                }
                Slider(value: Binding(get: { typography.size }, set: { size = $0 }), in: 16...30, step: 1)
                    .accessibilityLabel("Font size")
                    .accessibilityValue("\(Int(typography.size)) points")
            }
        }
    }

    private func fontCard(_ title: String, value: String) -> some View {
        let selected = typography.selection == value
        return Button { font = value } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aa あ").font(JournalTypography(font: value, size: 28).font).accessibilityHidden(true)
                Text(title).font(JournalDialogStyle.body)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? JournalDialogStyle.sage : .white, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? JournalDialogStyle.green : JournalDialogStyle.border, lineWidth: selected ? 2 : 1))
                .overlay(alignment: .topTrailing) {
                    if selected { Image(systemName: "checkmark").font(.system(size: 14)).foregroundStyle(JournalDialogStyle.green).padding(10).accessibilityHidden(true) }
                }
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

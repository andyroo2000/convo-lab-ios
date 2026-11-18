import SwiftUI

struct JournalKeyboardSheet: View {
    var onboarding = false
    @AppStorage(JournalKeyboardMode.key) private var storedMode = ""
    @State private var selection: JournalKeyboardMode?
    @Environment(\.dismiss) private var dismiss
    private let sage = Color(red: 0.929, green: 0.953, blue: 0.91)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    Text(onboarding ? "What keyboard do you use?" : "How would you like to type?")
                        .font(.custom("CrimsonPro-Regular", size: 29, relativeTo: .title))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Close keyboard choice")
                }
                VStack(spacing: 12) {
                    choice(.builtIn)
                    choice(.device)
                }
                if onboarding { JournalKeyboardGuide() }
                Button {
                    guard let selection else { return }
                    storedMode = selection.rawValue
                    dismiss()
                } label: {
                    Text(onboarding ? "Start writing" : "Done").frame(maxWidth: .infinity)
                }.buttonStyle(JournalDraftButtonStyle())
                    .disabled(selection == nil).accessibilityIdentifier("JournalKeyboardConfirm")
            }.padding(24)
        }
        .background(Color(red: 1, green: 0.992, blue: 0.961))
        .overlay(alignment: .top) { JournalDeskStyle.green.frame(height: 4) }
        .foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
        .environment(\.colorScheme, .light)
        .presentationDragIndicator(.visible)
        .onAppear { selection = JournalKeyboardMode(rawValue: storedMode) }
    }

    private func choice(_ mode: JournalKeyboardMode) -> some View {
        Button { selection = mode } label: {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if mode == .builtIn { Text("あ").font(.custom("KleeOne-SemiBold", size: 25)) }
                    else { Image(systemName: "keyboard") }
                }.frame(width: 38, height: 40)
                    .background(.white.opacity(0.6), in: .rect(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 7) {
                    Text(title(mode)).font(.custom("CrimsonPro-Regular", size: 22, relativeTo: .body))
                    Text(detail(mode)).font(.custom("CrimsonPro-Regular", size: 18, relativeTo: .body))
                        .foregroundStyle(Color(red: 0.45, green: 0.41, blue: 0.37))
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selection == mode ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection == mode ? JournalDeskStyle.green : .gray)
            }.padding(16).foregroundStyle(Color(red: 0.28, green: 0.41, blue: 0.29))
                .background(selection == mode ? sage : .white.opacity(0.4), in: .rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selection == mode ? JournalDeskStyle.green : Color.gray.opacity(0.25)))
        }.buttonStyle(.plain).accessibilityIdentifier("JournalKeyboard-\(mode.rawValue)")
            .accessibilityAddTraits(selection == mode ? .isSelected : [])
    }

    private func title(_ mode: JournalKeyboardMode) -> String {
        if onboarding { return mode == .builtIn ? "I use an English keyboard" : "I use a Japanese keyboard" }
        return mode == .builtIn ? "Built-in Japanese input" : "Use my keyboard"
    }
    private func detail(_ mode: JournalKeyboardMode) -> String {
        if onboarding { return mode == .builtIn ? "Convert romaji into Japanese as I write." : "Let my keyboard handle the conversion." }
        return mode == .builtIn ? "Type romaji with your English keyboard." : "Use your device’s Japanese keyboard."
    }
}

import SwiftUI

struct JournalQuestionControls: View {
    @Binding var showEnglish: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button { showEnglish.toggle() } label: {
                Text("En").font(.caption.weight(.semibold)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .foregroundStyle(showEnglish ? .white : JournalToolbarButtonStyle.blue)
                .background(showEnglish ? JournalToolbarButtonStyle.blue : .clear, in: .rect(cornerRadius: 8))
                .accessibilityLabel(showEnglish ? "Hide English" : "Show English")
                .accessibilityInputLabels(["En", "English"])

        }
    }
}

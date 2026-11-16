import SwiftUI

struct JournalQuestionControls: View {
    let busy: Bool
    @Binding var showEnglish: Bool
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { showEnglish.toggle() } label: {
                Text("En").font(.caption.weight(.semibold)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .foregroundStyle(showEnglish ? .white : JournalToolbarButtonStyle.blue)
                .background(showEnglish ? JournalToolbarButtonStyle.blue : .clear, in: .rect(cornerRadius: 8))
                .accessibilityLabel(showEnglish ? "Hide English" : "Show English")
                .accessibilityInputLabels(["En", "English"])
            Button(action: choose) {
                Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("Choose tutor").disabled(busy)
        }
    }
}

import SwiftUI

struct JournalQuestionControls: View {
    let translation: String
    let busy: Bool
    let choose: () -> Void
    @State private var showEnglish = false

    var body: some View {
        HStack(spacing: 0) {
            Button { showEnglish.toggle() } label: {
                Text("En").font(.caption.weight(.semibold)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(showEnglish ? "Hide English" : "Show English")
                .accessibilityInputLabels(["En", "English"])
                .popover(isPresented: $showEnglish) {
                    Text(translation).font(.subheadline).foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
                        .padding(16).frame(idealWidth: 280, maxWidth: 300)
                        .presentationCompactAdaptation(.popover)
                        .environment(\.colorScheme, .light)
                }
            Button(action: choose) {
                Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("Choose tutor").disabled(busy)
        }
    }
}

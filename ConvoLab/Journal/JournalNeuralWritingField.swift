import SwiftUI
import UIKit

struct JournalNeuralWritingField: UIViewRepresentable {
    @Environment(\.journalWritingFocus) private var focusChanged
    @Environment(\.journalCandidateBarVisibility) private var candidateBarVisibility
    @Binding var text: String
    let label: String
    let placeholder: String
    let minimumLines: Int
    var autofocus = false
    let unavailable: () -> Void
    @Environment(\.journalTypography) private var typography
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    func makeCoordinator() -> JournalTypingCoordinator { JournalTypingCoordinator(text: $text) }

    func makeUIView(context: Context) -> JournalNativeTextView {
        let view = JournalNativeTextView()
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: JournalNativeTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.focusChanged = focusChanged
        view.candidates.visibilityChanged = candidateBarVisibility
        context.coordinator.unavailable = unavailable
        view.placeholderText = placeholder
        context.coordinator.configure(text: text, font: typography.unscaledFont.withSize(typography.size * scale))
        view.focusOnAppearance = autofocus
        view.accessibilityLabel = label
        view.setEditingEnabled(enabled)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: JournalNativeTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.fittingSize(width: width, minimumLines: minimumLines)
    }

    static func dismantleUIView(_ view: JournalNativeTextView, coordinator: JournalTypingCoordinator) { coordinator.stop() }
}

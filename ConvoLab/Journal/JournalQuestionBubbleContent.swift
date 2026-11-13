import SwiftUI

struct JournalQuestionBubbleContent: View {
    let reading: String
    let translation: String
    let knownKanji: Set<Character>
    let busy: Bool
    let choose: () -> Void
    @State private var showEnglish = false
    @Environment(\.journalTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    var body: some View {
        JournalQuestionText(text: reading, knownKanji: knownKanji, font: typography.unscaledFont.withSize(typography.size * scale))
            .allowsHitTesting(false)
            .frame(minHeight: 44)
            .overlay(alignment: .topTrailing) {
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
}

private struct JournalQuestionText: UIViewRepresentable {
    let text: String
    let knownKanji: Set<Character>
    let font: UIFont

    func makeCoordinator() -> StudyRubyLineBreakDelegate { StudyRubyLineBreakDelegate() }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.overrideUserInterfaceStyle = .light
        view.textContainer.lineFragmentPadding = 0
        view.textLayoutManager?.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let document = StudyRubyDocument.parse(text, knownKanji: knownKanji)
        let attributed = document.attributedString(pointSize: font.pointSize, weight: .regular, color: JournalPopoverStyle.ink, alignment: .left, extraLineSpacing: 4, font: font)
        context.coordinator.updateRubyRanges(in: attributed)
        view.attributedText = attributed
        view.textContainerInset = UIEdgeInsets(top: document.hasRuby ? font.pointSize * 0.52 : 0, left: 0, bottom: 0, right: 0)
        view.accessibilityLabel = document.plainText
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        // Reserve only the first line for the two 44pt controls; later lines use the full bubble width.
        uiView.textContainer.exclusionPaths = [UIBezierPath(rect: CGRect(x: max(0, width - 96), y: 0, width: 96, height: 44))]
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
}

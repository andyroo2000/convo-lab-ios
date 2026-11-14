import SwiftUI
import UIKit

struct JournalSentenceText: View {
    let text: String
    let knownKanji: Set<Character>
    let player: JournalAudioPlayer
    var reserveControls = false
    @Environment(\.journalTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    var body: some View {
        JournalSentenceTextRepresentable(text: text, knownKanji: knownKanji, player: player,
            font: typography.unscaledFont.withSize(typography.size * scale), reserveControls: reserveControls)
    }
}

private struct JournalSentenceTextRepresentable: UIViewRepresentable {
    let text: String
    let knownKanji: Set<Character>
    let player: JournalAudioPlayer
    let font: UIFont
    let reserveControls: Bool

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }
    func makeUIView(context: Context) -> SentenceTextView {
        let view = SentenceTextView(usingTextLayoutManager: true)
        view.isEditable = false; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.overrideUserInterfaceStyle = .light
        view.textContainer.lineFragmentPadding = 0
        view.textLayoutManager?.delegate = context.coordinator.ruby
        view.delegate = context.coordinator
        view.moveSentence = { [weak player] in player?.moveSentence($0) }
        return view
    }

    func updateUIView(_ view: SentenceTextView, context: Context) {
        let current = player.engaged ? JournalSentenceTimeline.current(player.sentences, at: player.position) : nil
        let key = RenderKey(text: text, knownKanji: knownKanji, font: font, sentences: player.sentences, current: current)
        guard context.coordinator.rendered != key else { return }
        context.coordinator.rendered = key
        let document = StudyRubyDocument.parse(text, knownKanji: knownKanji)
        let attributed = NSMutableAttributedString(attributedString: document.attributedString(pointSize: font.pointSize,
            weight: .regular, color: JournalPopoverStyle.ink, alignment: .left, extraLineSpacing: 8, font: font))
        let ranges = JournalSentenceTimeline.ranges(player.sentences, text: document.plainText)
        for (index, range) in ranges.enumerated() {
            attributed.addAttribute(.link, value: "journal-sentence://\(index)", range: range)
        }
        if let current, ranges.indices.contains(current) {
            attributed.addAttribute(.backgroundColor, value: UIColor.systemBlue.withAlphaComponent(0.12), range: ranges[current])
        }
        context.coordinator.ruby.updateRubyRanges(in: attributed)
        view.accessibilityLabel = document.plainText
        view.accessibilityHint = "Tap a sentence to seek. Left and right arrows move by sentence."
        view.linkTextAttributes = [.foregroundColor: JournalPopoverStyle.ink, .underlineStyle: 0]
        if view.attributedText != attributed { view.attributedText = attributed }
        view.textContainerInset = UIEdgeInsets(top: document.hasRuby ? font.pointSize * 0.52 : 0, left: 0, bottom: 0, right: 0)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SentenceTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        uiView.textContainer.exclusionPaths = reserveControls
            ? [UIBezierPath(rect: CGRect(x: max(0, width - 96), y: 0, width: 96, height: 44))] : []
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    struct RenderKey: Equatable {
        let text: String
        let knownKanji: Set<Character>
        let font: UIFont
        let sentences: [JournalSentenceTiming]
        let current: Int?
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var rendered: RenderKey?
        let ruby = StudyRubyLineBreakDelegate()
        let player: JournalAudioPlayer
        init(player: JournalAudioPlayer) { self.player = player }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            guard URL.scheme == "journal-sentence", let host = URL.host, let index = Int(host), player.sentences.indices.contains(index) else { return false }
            textView.becomeFirstResponder()
            player.seek(player.sentences[index].start)
            return false
        }
    }
}

private final class SentenceTextView: UITextView {
    var moveSentence: ((Int) -> Void)?
    override var keyCommands: [UIKeyCommand]? {
        let commands = [UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(previousSentence)),
                        UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(nextSentence))]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }
    @objc private func previousSentence() { moveSentence?(-1) }
    @objc private func nextSentence() { moveSentence?(1) }
}

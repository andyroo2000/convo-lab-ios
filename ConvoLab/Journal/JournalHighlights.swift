import SwiftUI
import UIKit

struct JournalHighlights: UIViewRepresentable {
    let segments: [JournalSegment]
    let knownKanji: Set<Character>
    var document: JournalDocumentModel?
    var sourceID = ""

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.backgroundColor = .clear
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = false
        view.accessibilityIdentifier = "JournalHighlightedEntry"
        view.accessibilityHint = "Tap a highlighted phrase for its explanation and editing options."
        view.textContainer.lineFragmentPadding = 0
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.document = document
        context.coordinator.sourceID = sourceID
        context.coordinator.segments = segments
        context.coordinator.knownKanji = knownKanji
        let output = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for segment in segments {
            let text = NSMutableAttributedString(attributedString: StudyRubyDocument.parse(segment.reading, knownKanji: knownKanji)
                .attributedString(pointSize: 20, weight: .regular, color: .label, alignment: .left, extraLineSpacing: 10))
            let range = NSRange(location: output.length, length: text.length)
            ranges.append(range)
            if segment.kind.isHighlighted {
                let tint = Self.tint(segment.kind)
                text.addAttributes([.backgroundColor: tint.withAlphaComponent(0.12), .underlineColor: tint,
                                    .underlineStyle: Self.underline(segment.kind)], range: NSRange(location: 0, length: text.length))
            }
            output.append(text)
        }
        context.coordinator.ranges = ranges
        view.attributedText = output
        let size = UIFontMetrics.default.scaledValue(for: 20)
        view.textContainerInset = UIEdgeInsets(top: size * 0.52, left: 0, bottom: size * 0.08, right: 0)
        view.accessibilityLabel = segments.map(\.text).joined()
        view.accessibilityCustomActions = segments.enumerated().compactMap { index, segment in
            guard segment.kind.isHighlighted else { return nil }
            return UIAccessibilityCustomAction(name: "\(segment.kind.rawValue): \(segment.text)") { [weak coordinator = context.coordinator] _ in
                coordinator?.show(index)
                return true
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private static func tint(_ kind: JournalSegment.Kind) -> UIColor {
        switch kind { case .correction: .systemRed; case .optional: .systemOrange; case .keep, .plain: .label }
    }
    private static func underline(_ kind: JournalSegment.Kind) -> Int {
        switch kind {
        case .optional: NSUnderlineStyle.single.union(.patternDash).rawValue
        default: NSUnderlineStyle.single.rawValue
        }
    }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        weak var view: UITextView?
        var document: JournalDocumentModel?
        var sourceID = ""
        var segments: [JournalSegment] = []
        var ranges: [NSRange] = []
        var knownKanji: Set<Character> = []

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view, let position = view.closestPosition(to: gesture.location(in: view)) else { return }
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            let point = gesture.location(in: view)
            guard let hit = [offset, offset - 1].first(where: { contains(point, offset: $0, view: view) }),
                  let index = ranges.firstIndex(where: { NSLocationInRange(hit, $0) }) else { return }
            show(index)
        }

        private func contains(_ point: CGPoint, offset: Int, view: UITextView) -> Bool {
            guard offset >= 0, let start = view.position(from: view.beginningOfDocument, offset: offset),
                  let end = view.position(from: start, offset: 1), let character = view.textRange(from: start, to: end) else { return false }
            return view.firstRect(for: character).insetBy(dx: -2, dy: -6).contains(point)
        }

        func show(_ index: Int) {
            guard let view, segments.indices.contains(index), segments[index].kind.isHighlighted else { return }
            let controller = sequence(first: view.next, next: { $0?.next }).compactMap { $0 as? UIViewController }.first
            guard let controller, controller.presentedViewController == nil else { return }
            document?.errorMessage = nil
            // IDs retain the original segment index, including plain segments.
            let popup = UIHostingController(rootView: JournalCorrectionPopover(segment: segments[index], knownKanji: knownKanji, document: document, suggestionID: "\(sourceID):\(index)", width: min(320, (view.window?.bounds.width ?? 368) - 32), dismiss: { [weak controller] in controller?.dismiss(animated: true) }))
            popup.overrideUserInterfaceStyle = view.traitCollection.userInterfaceStyle
            popup.modalPresentationStyle = .popover
            popup.sizingOptions = .preferredContentSize
            if let presentation = popup.popoverPresentationController {
                presentation.delegate = self
                presentation.sourceView = view
                presentation.sourceRect = sourceRect(index, view: view)
                presentation.permittedArrowDirections = [.up, .down]
            }
            controller.present(popup, animated: true)
        }

        private func sourceRect(_ index: Int, view: UITextView) -> CGRect {
            guard let start = view.position(from: view.beginningOfDocument, offset: ranges[index].location),
                  let end = view.position(from: start, offset: ranges[index].length), let range = view.textRange(from: start, to: end) else { return view.bounds }
            return view.firstRect(for: range)
        }

        func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
    }
}

import SwiftUI
import UIKit

struct InteractivePopGestureGuard: UIViewControllerRepresentable {
    let isDisabled: Bool
    let onEscape: () -> Void

    func makeUIViewController(context _: Context) -> Controller {
        Controller(onEscape: onEscape)
    }

    func updateUIViewController(_ controller: Controller, context _: Context) {
        controller.update(isDisabled: isDisabled, onEscape: onEscape)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator _: Void) {
        controller.restoreGestureState()
    }

    final class Controller: UIViewController {
        private var isDisabled = false
        private weak var gestureRecognizer: UIGestureRecognizer?
        private var previouslyEnabled: Bool?
        private var onEscape: () -> Void

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyGestureState()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyGestureState()
        }

        override func viewWillDisappear(_ animated: Bool) {
            restoreGestureState()
            super.viewWillDisappear(animated)
        }

        override func accessibilityPerformEscape() -> Bool {
            guard isDisabled else { return super.accessibilityPerformEscape() }
            onEscape()
            return true
        }

        func update(isDisabled: Bool, onEscape: @escaping () -> Void) {
            self.isDisabled = isDisabled
            self.onEscape = onEscape
            applyGestureState()
        }

        func restoreGestureState() {
            guard let gestureRecognizer, let previouslyEnabled else { return }
            gestureRecognizer.isEnabled = previouslyEnabled
            self.gestureRecognizer = nil
            self.previouslyEnabled = nil
        }

        private func applyGestureState() {
            guard let nextGestureRecognizer = navigationController?.interactivePopGestureRecognizer
            else { return }

            if gestureRecognizer !== nextGestureRecognizer {
                restoreGestureState()
                gestureRecognizer = nextGestureRecognizer
                previouslyEnabled = nextGestureRecognizer.isEnabled
            }
            nextGestureRecognizer.isEnabled = isDisabled ? false : (previouslyEnabled ?? true)
        }
    }
}

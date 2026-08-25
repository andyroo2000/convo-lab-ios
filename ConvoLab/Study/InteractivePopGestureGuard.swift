import SwiftUI
import UIKit

struct InteractivePopGestureGuard: UIViewControllerRepresentable {
    let isDisabled: Bool

    func makeUIViewController(context _: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context _: Context) {
        controller.update(isDisabled: isDisabled)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator _: Void) {
        controller.restoreGestureState()
    }

    final class Controller: UIViewController {
        private var isDisabled = false
        private weak var gestureRecognizer: UIGestureRecognizer?
        private var previouslyEnabled: Bool?

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

        func update(isDisabled: Bool) {
            self.isDisabled = isDisabled
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

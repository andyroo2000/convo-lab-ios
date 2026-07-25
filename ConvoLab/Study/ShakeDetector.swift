import SwiftUI
import UIKit

struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        ShakeViewController(onShake: onShake)
    }

    func updateUIViewController(
        _ viewController: ShakeViewController,
        context: Context
    ) {
        viewController.onShake = onShake
        viewController.activate()
    }
}

final class ShakeViewController: UIViewController {
    var onShake: () -> Void

    init(onShake: @escaping () -> Void) {
        self.onShake = onShake
        super.init(nibName: nil, bundle: nil)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activate()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else {
            super.motionEnded(motion, with: event)
            return
        }
        onShake()
    }

    func activate() {
        guard isViewLoaded, view.window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
    }
}

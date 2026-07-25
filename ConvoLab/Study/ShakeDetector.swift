import SwiftUI
import UIKit

struct ShakeDetector: UIViewControllerRepresentable {
    let isEnabled: Bool
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        ShakeViewController(isEnabled: isEnabled, onShake: onShake)
    }

    func updateUIViewController(
        _ viewController: ShakeViewController,
        context: Context
    ) {
        viewController.onShake = onShake
        viewController.setEnabled(isEnabled)
    }
}

final class ShakeViewController: UIViewController {
    private var isEnabled: Bool
    var onShake: () -> Void

    init(isEnabled: Bool = true, onShake: @escaping () -> Void) {
        self.isEnabled = isEnabled
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
        isEnabled
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activate()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard isEnabled, motion == .motionShake else {
            super.motionEnded(motion, with: event)
            return
        }
        onShake()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            activate()
        } else if isFirstResponder {
            resignFirstResponder()
        }
    }

    func activate() {
        guard isEnabled, isViewLoaded, view.window != nil, !isFirstResponder else {
            return
        }
        becomeFirstResponder()
    }
}

import SwiftUI
import UIKit

extension View {
    func outsideDismissibleSheet<Content: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().background(OutsideSheetDismissal())
        }
    }

    func outsideDismissibleSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss) { item in
            content(item).background(OutsideSheetDismissal())
        }
    }
}

private struct OutsideSheetDismissal: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> OutsideSheetController {
        OutsideSheetController()
    }

    func updateUIViewController(_ controller: OutsideSheetController, context: Context) {
        controller.dismissSheet = { dismiss() }
    }
}

private final class OutsideSheetController: UIViewController, UIGestureRecognizerDelegate {
    var dismissSheet: (() -> Void)?
    private lazy var outsideTap = UITapGestureRecognizer(target: self, action: #selector(closeSheet))

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        outsideTap.delegate = self
        view.window?.addGestureRecognizer(outsideTap)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        outsideTap.view?.removeGestureRecognizer(outsideTap)
    }

    private var sheetController: UIViewController? {
        var controller: UIViewController? = self
        while let current = controller {
            if current.presentingViewController != nil { return current }
            controller = current.parent
        }
        return nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let sheet = sheetController, !sheet.isModalInPresentation,
              sheet.presentedViewController == nil,
              let presented = sheet.presentationController?.presentedView else { return false }
        return !presented.bounds.contains(touch.location(in: presented))
    }

    @objc private func closeSheet() { dismissSheet?() }
}

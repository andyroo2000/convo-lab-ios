import SwiftUI
import WebKit

struct TypingPlaygroundWebView: UIViewRepresentable {
  let model: TypingPlaygroundModel

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    #if DEBUG
      if UITestFixture.fromProcessArguments() == .typingPlayground {
        configuration.websiteDataStore = .nonPersistent()
      }
    #endif
    configuration.userContentController.addScriptMessageHandler(
      context.coordinator, contentWorld: .page, name: "typingEngine")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.isOpaque = false
    view.backgroundColor = UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
    view.scrollView.keyboardDismissMode = .interactive
    if let url = Bundle.main.url(forResource: "typing-playground", withExtension: "html") {
      view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    return view
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {}

  static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
    uiView.configuration.userContentController.removeScriptMessageHandler(
      forName: "typingEngine", contentWorld: .page)
    uiView.stopLoading()
  }

  @MainActor
  final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    weak var model: TypingPlaygroundModel?
    init(model: TypingPlaygroundModel) { self.model = model }

    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage,
      replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
      guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
        let payload = message.body as? [String: Any], let path = payload["path"] as? String,
        let model
      else {
        replyHandler(nil, "Unsupported playground request")
        return
      }
      let body = payload["body"] as? String
      Task { replyHandler(await model.bridge(path: path, body: body), nil) }
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }
  }
}

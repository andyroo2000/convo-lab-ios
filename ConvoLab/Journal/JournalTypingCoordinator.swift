import SwiftUI
import WebKit

@MainActor
final class JournalTypingCoordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    var text: Binding<String>
    var height: Binding<CGFloat>
    weak var view: WKWebView?
    var active = true
    private var loaded = false
    private var lastText: String?
    private var settings: JournalTypingSettings?
    private var revision = 0
    private static let engine = TypingEngineActor()

    init(text: Binding<String>, height: Binding<CGFloat>) {
        self.text = text
        self.height = height
    }

    func configure(text: String, settings: JournalTypingSettings) {
        guard lastText != text || self.settings != settings else { return }
        if lastText != text { revision += 1 }
        lastText = text
        self.settings = settings
        sendConfiguration()
    }

    private func sendConfiguration() {
        guard loaded, let settings, let data = try? JSONEncoder().encode(settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        view?.callAsyncJavaScript("window.journal.configure(text, settings, revision)",
            arguments: ["text": lastText ?? "", "settings": object, "revision": revision], in: nil, in: .page, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        sendConfiguration()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard active, message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let payload = message.body as? [String: Any], let path = payload["path"] as? String
        else { replyHandler(nil, "Unsupported editor request"); return }
        if path == "journal/change" {
            receiveChange(payload)
            replyHandler("{}", nil)
        } else if path == "journal/layout" {
            receiveLayout(payload)
            replyHandler("{}", nil)
        } else {
            let body = payload["body"] as? String
            Task { replyHandler(await Self.convert(path: path, body: body), nil) }
        }
    }

    private func receiveChange(_ payload: [String: Any]) {
        guard let value = payload["text"] as? String,
              payload["revision"] as? Int == revision else { return }
        lastText = value
        text.wrappedValue = value
    }

    private func receiveLayout(_ payload: [String: Any]) {
        if let value = payload["height"] as? Double, value.isFinite, value > 0 {
            height.wrappedValue = CGFloat(value)
        }
        guard payload["focused"] as? Bool == true, let y = payload["caret"] as? Double, y.isFinite,
              let view else { return }
        let revealHeight = min(380, max(65, payload["revealHeight"] as? Double ?? 65))
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            var ancestor = view.superview
            while let parent = ancestor {
                if let scroll = parent as? UIScrollView, scroll.isScrollEnabled {
                    let rect = CGRect(x: 0, y: y, width: 10, height: revealHeight)
                    scroll.scrollRectToVisible(view.convert(rect, to: scroll), animated: false)
                    return
                }
                ancestor = parent.superview
            }
        }
    }

    private static func convert(path: String, body: String?) async -> String {
        do {
            _ = try await engine.prepare()
            if path == "/api/v1/engine" || path == "/api/v1/engine/retry" { return "{\"state\":\"ready\"}" }
            if path == "/api/v1/convert", let body { return try await engine.convert(body) }
            return "{\"error\":\"Unsupported input request\"}"
        } catch { return "{\"error\":\"Could not prepare Japanese input. Retry or choose your device keyboard from the menu.\"}" }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

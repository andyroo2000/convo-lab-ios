import SwiftUI
import WebKit

struct ReadingWebView: UIViewRepresentable {
    let reading: ReadingDetail
    let pageIndex: Int
    let format: ReadingFormat
    let theme: ReadingTheme
    let selectedSentence: Int?
    let store: ReadingStore
    let onEvent: (String, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "reading")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.accessibilityIdentifier = "reading-page"
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let key = "\(reading.id):\(reading.revision):\(pageIndex):\(format.rawValue):\(theme.id)"
        if coordinator.key != key {
            coordinator.key = key
            coordinator.imageTask?.cancel()
            view.loadHTMLString(html(), baseURL: nil)
        } else if coordinator.selected != selectedSentence {
            view.evaluateJavaScript("window.readerSelect(\(selectedSentence.map(String.init) ?? "null"), false)")
        }
        coordinator.selected = selectedSentence
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.imageTask?.cancel()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "reading")
        view.navigationDelegate = nil
        view.stopLoading()
    }

    private func html() -> String {
        let document = (try? JSONEncoder().encode(reading.document)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let safeDocument = document.replacingOccurrences(of: "<", with: "\\u003c")
        let css = resource("css")
        let script = resource("js")
        let mode: String = switch format { case .original: "original"; case .reflow: "reflow"; case .companion: "companion" }
        let names = ["paper", "surface", "ink", "secondary", "border", "selection", "accent"]
        let colors = zip(names, theme.colors).map { "--\($0):\($1);" }.joined()
        return """
        <!doctype html><html lang="ja"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <style>:root{\(colors)color-scheme:\(theme.isDark ? "dark" : "light");}\(css)</style></head>
        <body><main id="page" class="\(mode)"></main><aside id="translation" hidden role="note" aria-label="Translation"></aside>
        <script>\(script)\nReadingReader.mount(\(safeDocument),\(pageIndex),\(selectedSentence.map(String.init) ?? "null"));</script></body></html>
        """
    }

    private func resource(_ type: String) -> String {
        guard let url = Bundle.main.url(forResource: "reading-reader", withExtension: type) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ReadingWebView
        var key = ""
        var selected: Int?
        var imageTask: Task<Void, Never>?

        init(_ parent: ReadingWebView) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let payload = message.body as? [String: Any],
                  let event = payload["event"] as? String,
                  ["select", "play"].contains(event),
                  let index = payload["index"] as? Int else { return }
            parent.onEvent(event, index)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard parent.reading.document.pages.indices.contains(parent.pageIndex) else { return }
            let page = parent.reading.document.pages[parent.pageIndex]
            let cover = page.kind == "title" ? parent.reading.illustrationUrl : nil
            guard let path = page.imageUrl ?? cover else { return }
            let requestKey = key
            imageTask = Task { [weak self, weak webView] in
                guard let self else { return }
                do {
                    try parent.store.checkSession()
                    let bytes = try await parent.store.resource(path, key: "image:\(parent.reading.revision):\(path)")
                    try parent.store.checkSession()
                    guard key == requestKey else { return }
                    guard UIImage(data: bytes) != nil else {
                        parent.store.invalidateResource(key: "image:\(parent.reading.revision):\(path)")
                        throw APIClientError.invalidResponse
                    }
                    let url = "data:image/\(bytes.starts(with: [0x89, 0x50, 0x4e, 0x47]) ? "png" : "jpeg");base64,\(bytes.base64EncodedString())"
                    let value = String(data: try JSONEncoder().encode(url), encoding: .utf8) ?? "null"
                    _ = try await webView?.evaluateJavaScript("window.readerImage(\(value))")
                } catch is CancellationError { return }
                catch { parent.store.errorMessage = error.localizedDescription }
            }
        }
    }
}

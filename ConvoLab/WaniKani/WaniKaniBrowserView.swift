import Combine
import SwiftUI
import WebKit

enum WaniKaniURLPolicy {
    nonisolated enum NavigationDisposition: Equatable {
        case allow
        case loadInMainFrame
        case openAuxiliaryWindow
        case openExternally
        case cancel
    }

    nonisolated static var reviewURL: URL {
        URL(string: "https://www.wanikani.com/subjects/review")!
    }

    nonisolated static func isWaniKaniPage(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "wanikani.com" || host.hasSuffix(".wanikani.com")
    }

    nonisolated static func isReviewPage(_ url: URL?) -> Bool {
        guard isWaniKaniPage(url) else { return false }
        let path = url?.path.lowercased() ?? ""
        return path == "/subjects/review" || path.hasPrefix("/subjects/review/")
    }

    nonisolated static func navigationDisposition(
        for url: URL?,
        targetIsMainFrame: Bool?,
        isUserActivated: Bool
    ) -> NavigationDisposition {
        let scheme = url?.scheme?.lowercased()
        let isWebContent = scheme == "http" || scheme == "https" || scheme == "about"

        // A nil target is JavaScript's window.open(). Keep background authentication
        // windows in WebKit, but preserve normal behavior for links the user tapped.
        if targetIsMainFrame == nil {
            guard isWebContent else {
                return isUserActivated ? .openExternally : .cancel
            }
            guard isUserActivated else { return .openAuxiliaryWindow }
            return isWaniKaniPage(url) ? .loadInMainFrame : .openExternally
        }

        // Third-party authentication and fraud-detection content commonly lives in an
        // iframe. It must remain embedded instead of being promoted to the system browser.
        if targetIsMainFrame == false {
            return isWebContent ? .allow : .cancel
        }

        guard isWebContent else { return .openExternally }
        if scheme == "about" || isWaniKaniPage(url) {
            return .allow
        }
        return .openExternally
    }
}

@MainActor
@Observable
final class WaniKaniBrowserModel: NSObject, WKNavigationDelegate, WKScriptMessageHandler,
    WKUIDelegate
{
    static let idleInterval: TimeInterval = 5 * 60

    let webView: WKWebView
    private(set) var currentURL: URL?
    private(set) var lastInteractionAt: Date?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var errorMessage: String?

    private var hasLoadedInitialPage = false
    private var auxiliaryWebViews: [ObjectIdentifier: WKWebView] = [:]

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.activityBridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: "convoLabWaniKani"
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func loadInitialPage() {
        guard !hasLoadedInitialPage else { return }
        hasLoadedInitialPage = true
        webView.load(URLRequest(url: WaniKaniURLPolicy.reviewURL))
    }

    func reload() {
        errorMessage = nil
        webView.reload()
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func isRecentlyActive(at date: Date = .now) -> Bool {
        guard let lastInteractionAt else { return false }
        return date.timeIntervalSince(lastInteractionAt) < Self.idleInterval
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.webView === webView,
              message.name == "convoLabWaniKani",
              let event = message.body as? [String: Any],
              let urlString = event["url"] as? String,
              let url = URL(string: urlString),
              WaniKaniURLPolicy.isWaniKaniPage(url)
        else {
            return
        }

        currentURL = url
        refreshNavigationState(webView)
        if event["kind"] as? String == "activity" {
            lastInteractionAt = .now
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        isLoading = true
        errorMessage = nil
        refreshNavigationState(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        isLoading = false
        currentURL = webView.url
        lastInteractionAt = .now
        refreshNavigationState(webView)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard webView === self.webView else { return }
        handleNavigationFailure(error, webView: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard webView === self.webView else { return }
        handleNavigationFailure(error, webView: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // Once an auxiliary window exists, its redirects must stay in that same invisible
        // WebKit context so cookies and window.opener-based completion keep working.
        if webView !== self.webView {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            return scheme == "http" || scheme == "https" || scheme == "about"
                ? .allow
                : .cancel
        }

        let disposition = WaniKaniURLPolicy.navigationDisposition(
            for: navigationAction.request.url,
            targetIsMainFrame: navigationAction.targetFrame?.isMainFrame,
            isUserActivated: navigationAction.navigationType == .linkActivated
        )
        switch disposition {
        case .allow, .openAuxiliaryWindow:
            return .allow
        case .loadInMainFrame:
            webView.load(navigationAction.request)
            return .cancel
        case .openExternally:
            if let url = navigationAction.request.url {
                await UIApplication.shared.open(url)
            }
            return .cancel
        case .cancel:
            return .cancel
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              navigationAction.navigationType != .linkActivated
        else {
            return nil
        }

        let auxiliaryWebView = WKWebView(frame: .zero, configuration: configuration)
        auxiliaryWebView.navigationDelegate = self
        auxiliaryWebView.uiDelegate = self
        auxiliaryWebViews[ObjectIdentifier(auxiliaryWebView)] = auxiliaryWebView
        return auxiliaryWebView
    }

    func webViewDidClose(_ webView: WKWebView) {
        auxiliaryWebViews.removeValue(forKey: ObjectIdentifier(webView))
    }

    private func refreshNavigationState(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func handleNavigationFailure(_ error: any Error, webView: WKWebView) {
        isLoading = false
        refreshNavigationState(webView)
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        errorMessage = error.localizedDescription
    }

    private static let activityBridgeScript = """
        (() => {
          const handler = window.webkit?.messageHandlers?.convoLabWaniKani;
          if (!handler || window.__convoLabWaniKaniBridgeInstalled) return;
          window.__convoLabWaniKaniBridgeInstalled = true;

          let lastActivity = 0;
          const post = kind => handler.postMessage({ kind, url: window.location.href });
          const activity = () => {
            const now = Date.now();
            if (now - lastActivity < 1000) return;
            lastActivity = now;
            post("activity");
          };

          for (const method of ["pushState", "replaceState"]) {
            const original = history[method];
            history[method] = function(...args) {
              const result = original.apply(this, args);
              post("location");
              return result;
            };
          }

          window.addEventListener("popstate", () => post("location"));
          window.addEventListener("hashchange", () => post("location"));
          document.addEventListener("turbo:load", () => post("location"));
          document.addEventListener("turbo:render", () => post("location"));
          document.addEventListener("pointerdown", activity, { passive: true });
          document.addEventListener("keydown", activity, { passive: true });
          post("location");
        })();
        """
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: (any WKScriptMessageHandler)?

    init(delegate: any WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

private struct WaniKaniWebView: UIViewRepresentable {
    let browser: WaniKaniBrowserModel

    func makeUIView(context: Context) -> WKWebView {
        browser.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

struct WaniKaniBrowserView: View {
    let timeStore: StudyTimeStore?

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var browser = WaniKaniBrowserModel()
    @State private var isVisible = false

    private let idleTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            WaniKaniWebView(browser: browser)

            if let errorMessage = browser.errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t open WaniKani", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        browser.reload()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.regularMaterial)
            }
        }
        .navigationTitle("WaniKani")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Back", systemImage: "chevron.backward") {
                    browser.goBack()
                }
                .disabled(!browser.canGoBack)

                Button("Forward", systemImage: "chevron.forward") {
                    browser.goForward()
                }
                .disabled(!browser.canGoForward)

                Spacer()

                if browser.isLoading {
                    ProgressView()
                        .accessibilityLabel("Loading WaniKani")
                }

                Button("Reload", systemImage: "arrow.clockwise") {
                    browser.reload()
                }

                Button("Open in Safari", systemImage: "safari") {
                    openURL(browser.currentURL ?? WaniKaniURLPolicy.reviewURL)
                }
            }
        }
        .onAppear {
            isVisible = true
            browser.loadInitialPage()
            updateTimeTracking()
        }
        .onDisappear {
            isVisible = false
            stopTimeTracking()
        }
        .onChange(of: scenePhase) {
            updateTimeTracking()
        }
        .onChange(of: browser.currentURL) {
            updateTimeTracking()
        }
        .onChange(of: browser.lastInteractionAt) {
            updateTimeTracking()
        }
        .onReceive(idleTimer) { date in
            updateTimeTracking(at: date)
        }
    }

    private func updateTimeTracking(at date: Date = .now) {
        guard isVisible,
              scenePhase == .active,
              WaniKaniURLPolicy.isReviewPage(browser.currentURL)
        else {
            stopTimeTracking(at: date)
            return
        }
        guard browser.isRecentlyActive(at: date) else {
            stopTimeTracking(at: browser.lastInteractionAt ?? date)
            return
        }
        timeStore?.start(
            activity: .wanikaniReview,
            source: .automatic,
            name: "WaniKani Reviews",
            at: browser.lastInteractionAt ?? date
        )
    }

    private func stopTimeTracking(at date: Date = .now) {
        timeStore?.stop(
            activity: .wanikaniReview,
            source: .automatic,
            at: date
        )
    }
}

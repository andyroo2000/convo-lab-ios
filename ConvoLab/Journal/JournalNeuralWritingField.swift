import SwiftUI
import WebKit

struct JournalNeuralWritingField: View {
    @Binding var text: String
    let label: String
    let minimumLines: Int
    @State private var height: CGFloat = 200
    @Environment(\.journalTypography) private var typography
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    var body: some View {
        JournalTypingWebView(text: $text, height: $height,
            settings: JournalTypingSettings(label: label, font: typography.unscaledFont.fontName,
                size: typography.size * scale, lines: minimumLines, enabled: enabled))
            .frame(height: max(height, typography.size * scale * JournalPaperText.linePitch * Double(minimumLines)))
    }
}

struct JournalTypingSettings: Equatable, Encodable {
    let label: String
    let font: String
    let size: Double
    let lines: Int
    let enabled: Bool
}

struct JournalTypingWebView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let settings: JournalTypingSettings

    func makeCoordinator() -> JournalTypingCoordinator {
        JournalTypingCoordinator(text: $text, height: $height)
    }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "typingEngine")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.backgroundColor = .clear
        context.coordinator.view = view
        if let url = Bundle.main.url(forResource: "journal-typing", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.height = $height
        context.coordinator.configure(text: text, settings: settings)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: JournalTypingCoordinator) {
        coordinator.active = false
        view.configuration.userContentController.removeScriptMessageHandler(forName: "typingEngine", contentWorld: .page)
        view.stopLoading()
    }
}

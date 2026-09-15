import Observation
import SwiftUI
import WebKit

/// Owns the WKWebView used for "From a link" captures. Non-private data store so JSTOR /
/// university-proxy logins stick between runs; Safari UA so sites serve their normal pages.
@Observable @MainActor
final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    var urlText = ""
    var pageTitle = ""
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var isOpen = false

    @ObservationIgnored let webView: WKWebView

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.customUserAgent = Self.safariUA
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        urlText = s
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    private func sync() {
        urlText = webView.url?.absoluteString ?? urlText
        pageTitle = webView.title ?? ""
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { sync() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { sync() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sync() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { sync() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { sync() }

    // Links that want a new window (target=_blank) open in this same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// The "Narrate Browser" window: address bar, the page, and a Capture button.
struct BrowserWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var browser = model.browser
        WebViewRepresentable(webView: browser.webView)
            .frame(minWidth: 700, minHeight: 500)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!browser.canGoBack)
                    Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!browser.canGoForward)
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: browser.isLoading ? "arrow.triangle.2.circlepath" : "globe")
                            .foregroundStyle(.secondary).font(.caption)
                        TextField("Enter a URL", text: $browser.urlText)
                            .textFieldStyle(.plain)
                            .onSubmit { browser.load(browser.urlText) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    .frame(minWidth: 320, idealWidth: 520)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.capturePage()
                    } label: {
                        if model.isCapturing {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(model.captureLabel) }
                        } else {
                            Label("Capture Page Text", systemImage: "text.viewfinder").labelStyle(.titleAndIcon)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isCapturing)
                }
            }
            .navigationTitle(browser.pageTitle.isEmpty ? "Narrate Browser" : browser.pageTitle)
            .navigationSubtitle("Sign in if needed, get the article on screen, then Capture")
            .onAppear { browser.isOpen = true }
            .onDisappear { browser.isOpen = false }
    }
}

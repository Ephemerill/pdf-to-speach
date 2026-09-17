import Observation
import SwiftUI
import WebKit

/// Owns the WKWebView behind the Link source. It loads pages whether or not the browser window is
/// showing (reading an article never needs the window), and the window simply displays the same
/// view for the sign-in / JSTOR / Capture cases. Non-private data store so logins stick between
/// runs; Safari UA so sites serve their normal pages.
@Observable @MainActor
final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    enum LoadOutcome { case page, pdf(URL) }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    var urlText = ""
    var pageTitle = ""
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var isOpen = false
    /// A PDF the user navigated to in the window (as opposed to one `load(_:)` was waiting for).
    var onDownloadedPDF: ((URL) -> Void)?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var loadWaiter: CheckedContinuation<LoadOutcome, Error>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var download: WKDownload?
    @ObservationIgnored private var downloadDestination: URL?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.preferences.isElementFullscreenEnabled = true
        // A real size even while no window shows it: pages lay out (and lazy-load) as on a laptop screen.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1100, height: 820), configuration: cfg)
        super.init()
        webView.customUserAgent = Self.safariUA
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(_ text: String) {
        guard let url = Self.webURL(from: text) else { return }
        urlText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    /// "example.com/x" → https://example.com/x; nil for anything that isn't a web address.
    static func webURL(from text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            guard s.range(of: #"^[\w.-]+\.[a-z]{2,}(/|$|:\d)"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
            s = "https://" + s
        }
        guard let url = URL(string: s), let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    /// Load a page and return once it has finished (or turned out to be a PDF, which is downloaded
    /// to ~/Downloads instead). A second call supersedes an unfinished one.
    func load(_ url: URL) async throws -> LoadOutcome {
        finishLoad(.failure(Failure(message: "superseded by another load")))
        loadGeneration += 1
        let generation = loadGeneration
        urlText = url.absoluteString
        Task {   // safety net: a page that never finishes (or a download that stalls) must not hang the app
            try? await Task.sleep(for: .seconds(45))
            if generation == loadGeneration { finishLoad(.failure(Failure(message: "the page took too long to load"))) }
        }
        return try await withCheckedThrowingContinuation { cont in
            loadWaiter = cont
            webView.load(URLRequest(url: url))
        }
    }

    /// After `load`, give scripts a moment to render (client-side apps fill the page in after `didFinish`).
    func settle() async {
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(250))
            if !webView.isLoading { break }
        }
        try? await Task.sleep(for: .milliseconds(600))
    }

    private func finishLoad(_ result: Result<LoadOutcome, Error>) {
        guard let cont = loadWaiter else { return }
        loadWaiter = nil
        cont.resume(with: result)
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
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sync(); finishLoad(.success(.page)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { sync(); failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { sync(); failed(error) }

    private func failed(_ error: Error) {
        let e = error as NSError
        // -999: replaced by a newer navigation. WebKit 102: the response became a download (see below).
        if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }
        finishLoad(.failure(error))
    }

    // MARK: PDFs — save the file and hand it to the app instead of showing it in the web view.

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, navigationResponse.response.mimeType?.lowercased() == "application/pdf" { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        self.download = download
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var name = suggestedFilename.isEmpty ? "Document.pdf" : suggestedFilename
        if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        var dest = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\((name as NSString).deletingPathExtension) \(n).pdf"); n += 1
        }
        downloadDestination = dest
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloadDestination else { finishLoad(.failure(Failure(message: "the download vanished"))); return }
        self.download = nil; downloadDestination = nil
        isLoading = false
        if loadWaiter != nil { finishLoad(.success(.pdf(file))) } else { onDownloadedPDF?(file) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        self.download = nil
        isLoading = false
        finishLoad(.failure(error))
    }

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

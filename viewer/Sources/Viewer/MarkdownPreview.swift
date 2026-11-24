import AppKit
import WebKit

@MainActor final class MarkdownPreview: WKWebView, WKNavigationDelegate {
    private let files: MarkdownFiles
    private var source = ""
    private var loaded = false
    private var generation = 0
    private(set) var isReady = false
    private(set) var renderError: Error?

    init(directory: URL) {
        files = MarkdownFiles(directory: directory)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(files, forURLScheme: MarkdownFiles.scheme)
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = self
        underPageBackgroundColor = Theme.background
        let template = try? String(contentsOf: MarkdownFiles.assets.appendingPathComponent("preview.html"), encoding: .utf8)
        loadHTMLString(template ?? "<p>Cannot load Markdown preview.</p>", baseURL: MarkdownFiles.baseURL)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ source: String) {
        self.source = source
        isReady = false
        renderError = nil
        generation += 1
        if loaded { render() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        render()
    }

    private func render() {
        let current = generation
        callAsyncJavaScript("renderMarkdown(source)", arguments: ["source": source], in: nil, in: .page) { [weak self] result in
            guard let self, generation == current else { return }
            if case .failure(let error) = result { renderError = error }
            isReady = true
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return decisionHandler(.allow) }
        if url.scheme == MarkdownFiles.scheme, url.path == "/", url.fragment != nil { return decisionHandler(.allow) }
        if let file = files.documentURL(for: url) { NSWorkspace.shared.open(file) }
        else if ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
}

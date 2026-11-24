import Foundation
import UniformTypeIdentifiers
import WebKit

final class MarkdownFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "viewer-markdown"
    static let baseURL = URL(string: "viewer-markdown://document/")!
    static var assets: URL {
        let installed = Bundle.main.resourceURL?.appendingPathComponent("Markdown")
        if let installed, FileManager.default.fileExists(atPath: installed.path) { return installed }
        return Bundle.module.url(forResource: "Markdown", withExtension: nil)!
    }
    private let directory: URL

    init(directory: URL) { self.directory = directory.resolvingSymlinksInPath() }

    func documentURL(for url: URL) -> URL? {
        guard url.scheme == Self.scheme, url.host == "document" else { return nil }
        return directory.appendingPathComponent(String(url.path.dropFirst())).standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let root = url.host == "assets" ? Self.assets : directory
        let file = root.appendingPathComponent(String(url.path.dropFirst())).resolvingSymlinksInPath()
        guard ["assets", "document"].contains(url.host ?? ""),
              file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError))
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

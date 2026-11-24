import AppKit

@MainActor enum MarkdownCheck {
    private static let previewTimeout = 15.0
    private static let pollNanoseconds: UInt64 = 20_000_000
    private static let source = """
    # Heading

    A **bold** and *italic* [link](https://example.com).

    | Name | Value |
    | --- | --- |
    | First | 1 |

    ![Fixture](picture.png)

    1. Parent
       - Child
    2. Last

    - [x] Complete

    ```swift
    let value = 1
    ```

    > Quoted text

    <script>window.previewInjected = true</script>
    <img src="missing.png" onerror="window.previewInjected = true">
    """

    static func run(document: URL?) async -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-markdown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("fixture.md")
            try source.write(to: file, atomically: true, encoding: .utf8)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("picture.png"))
            let preview = MarkdownPreview(directory: directory)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = preview
            defer { window.contentView = nil }
            preview.show(source)
            try await settle(preview)
            var passed = try await checkDOM(preview)
            passed = try checkSwitching(file) && passed
            if let document { passed = try await checkDocument(document) && passed }
            return passed
        } catch {
            print("FAIL: Markdown preview loads and renders without errors")
            return false
        }
    }

    private static func checkDOM(_ preview: MarkdownPreview) async throws -> Bool {
        let checks = [
            ("document.querySelector('h1')?.textContent === 'Heading'", "renders a heading"),
            ("document.querySelectorAll('table th').length === 2 && document.querySelectorAll('table td').length === 2",
             "renders Markdown cells as a table instead of separate paragraphs"),
            ("document.querySelector('img[alt=Fixture]')?.naturalWidth === 2", "loads a relative image instead of only its alternative text"),
            ("!!document.querySelector('strong') && !!document.querySelector('em')", "renders bold and italic emphasis"),
            ("document.querySelector('a')?.href === 'https://example.com/'", "preserves clickable links"),
            ("!!document.querySelector('ol > li > ul > li')", "renders nested lists"),
            ("document.querySelector('input[type=checkbox]')?.checked === true", "renders task list checkboxes"),
            ("document.querySelector('pre code')?.textContent === 'let value = 1\\n'", "renders a fenced code block"),
            ("!!document.querySelector('blockquote')", "renders a blockquote"),
            ("!document.querySelector('#content script, #content [onerror]') && !window.previewInjected", "keeps document scripts inactive"),
            ("getComputedStyle(document.querySelector('.markdown-body')).maxWidth === '980px'", "uses a readable document width"),
        ]
        var passed = true
        for (expression, name) in checks {
            let result = try await preview.evaluateJavaScript(expression) as? Bool == true
            print("\(result ? "ok" : "FAIL"): \(name)")
            passed = result && passed
        }
        return passed
    }

    private static func checkSwitching(_ file: URL) throws -> Bool {
        let doc = try Document(url: file)
        let media = TextMedia(doc, onDrop: { _ in }, onReload: {})
        doc.storage.append(NSAttributedString(string: "\nUnsaved text"))
        doc.dirty = true
        let edited = doc.storage.string
        media.showMarkdownPreview(true)
        let showsPreview = media.previewsMarkdown
        media.showMarkdownPreview(false)
        let saved = try String(contentsOf: file, encoding: .utf8)
        let passed = showsPreview && !media.previewsMarkdown && doc.storage.string == edited && doc.dirty
            && saved == source
        print("\(passed ? "ok" : "FAIL"): switching modes preserves unsaved edits and the original file")
        return passed
    }

    private static func checkDocument(_ file: URL) async throws -> Bool {
        let preview = MarkdownPreview(directory: file.deletingLastPathComponent())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = preview
        defer { window.contentView = nil }
        preview.show(try String(contentsOf: file, encoding: .utf8))
        try await settle(preview)
        let passed = try await preview.evaluateJavaScript("""
            !!document.querySelector('table th') && !!document.querySelector('table td') &&
            [...document.images].some(image => image.naturalWidth > 0)
            """) as? Bool == true
        print("\(passed ? "ok" : "FAIL"): the supplied document displays its table and image")
        return passed
    }

    private static func settle(_ preview: MarkdownPreview) async throws {
        let deadline = Date().addingTimeInterval(previewTimeout)
        while Date() < deadline {
            if preview.isReady {
                if let error = preview.renderError { throw error }
                let loaded = try await preview.evaluateJavaScript("[...document.images].every(image => image.complete)") as? Bool
                if loaded == true { return }
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        throw CocoaError(.fileReadUnknown)
    }
}

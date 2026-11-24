import AppKit

@MainActor final class MarkdownPreview: NSScrollView {
    private static let bodySize: CGFloat = 15
    private static let indent: CGFloat = 22
    let textView = NSTextView(usingTextLayoutManager: false)

    init() {
        super.init(frame: .zero)
        automaticallyAdjustsContentInsets = false
        hasVerticalScroller = true
        autohidesScrollers = true
        backgroundColor = Theme.background
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.backgroundColor = Theme.background
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ source: String) { textView.textStorage?.setAttributedString(Self.formatted(source)) }

    static func formatted(_ source: String) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return NSAttributedString(string: source, attributes: Theme.base)
        }
        let result = NSMutableAttributedString()
        var block: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let startsBlock = components.first?.identity != block
            if startsBlock, result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            block = components.first?.identity
            let part = NSMutableAttributedString(AttributedString(parsed[run.range]))
            var attributes = attributes(for: run)
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 10
            paragraph.lineSpacing = 4
            let listItem = components.first { if case .listItem = $0.kind { return true }; return false }
            let list = components.first {
                switch $0.kind { case .orderedList, .unorderedList: return true; default: return false }
            }
            for component in components {
                switch component.kind {
                case .header(let level):
                    attributes[.font] = NSFont.systemFont(ofSize: bodySize + CGFloat(7 - level) * 2, weight: .bold)
                case .codeBlock:
                    attributes[.font] = Theme.font
                    attributes[.backgroundColor] = Theme.lineHighlight
                    paragraph.paragraphSpacing = 0
                case .listItem(let ordinal):
                    paragraph.headIndent += indent
                    paragraph.firstLineHeadIndent = paragraph.headIndent - indent
                    if startsBlock, component.identity == listItem?.identity {
                        let ordered = list.map { if case .orderedList = $0.kind { return true }; return false } ?? false
                        let marker = ordered ? "\(ordinal). " : "• "
                        part.insert(NSAttributedString(string: marker), at: 0)
                    }
                case .blockQuote:
                    paragraph.headIndent += indent
                    paragraph.firstLineHeadIndent = paragraph.headIndent
                    attributes[.foregroundColor] = Theme.lineNumber
                default: break
                }
            }
            attributes[.paragraphStyle] = paragraph
            part.addAttributes(attributes, range: NSRange(location: 0, length: part.length))
            result.append(part)
        }
        return result
    }

    private static func attributes(for run: AttributedString.Runs.Run) -> [NSAttributedString.Key: Any] {
        let intent = run.inlinePresentationIntent ?? []
        var font = NSFont.systemFont(ofSize: bodySize)
        if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        if intent.contains(.code) { font = Theme.font }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.foreground]
        if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if intent.contains(.code) { attributes[.backgroundColor] = Theme.lineHighlight }
        return attributes
    }
}

import AppKit

private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
    info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
}

/// A file dropped on the text opens it instead of pasting its path; the cursor's line is lit.
final class CodeView: NSTextView {
    var onDrop: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onDrop?(urls)
        return true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard isEditable, selectedRange().length == 0, var line = currentLineRect() else { return }
        line.origin.x = 0
        line.size.width = bounds.width
        Theme.lineHighlight.setFill()
        line.intersection(rect).fill()
    }

    /// The whole of the cursor's line, all its wrapped rows.
    private func currentLineRect() -> NSRect? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let text = string as NSString
        let location = selectedRange().location
        var rect: NSRect
        if location >= text.length, text.length == 0 || text.character(at: text.length - 1) == 0x0A {
            rect = layout.extraLineFragmentRect
            rect.size.height = Theme.lineHeight
        } else {
            let paragraph = text.paragraphRange(for: NSRange(location: min(location, text.length), length: 0))
            let glyphs = layout.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        }
        return rect.offsetBy(dx: 0, dy: textContainerOrigin.y)
    }
}

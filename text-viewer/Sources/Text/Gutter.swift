import AppKit

/// The line numbers left of the text, as VS Code draws them: dim, the cursor's line bright.
final class Gutter: NSRulerView {
    static let leading: CGFloat = 14
    static let trailing: CGFloat = 18
    static let minDigits = 3
    static let numberFont = Theme.font

    private var lineStarts: [Int] = [0]
    private var linesValid = false

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification,
                                               object: textView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    private var textView: NSTextView? { clientView as? NSTextView }

    /// After the text view shows another file, or a file reloads.
    @objc func textChanged() {
        linesValid = false
        let width = Self.leading + Self.trailing + digitWidth * CGFloat(max(Self.minDigits, String(lines.count).count))
        if ruleThickness != width { ruleThickness = width }
        needsDisplay = true
    }

    @objc func redraw() { needsDisplay = true }

    private var digitWidth: CGFloat { ("8" as NSString).size(withAttributes: [.font: Self.numberFont]).width }

    private var lines: [Int] {
        if !linesValid, let text = textView?.string as NSString? {
            var starts = [0]
            var i = 0
            while i < text.length {
                i = NSMaxRange(text.lineRange(for: NSRange(location: i, length: 0)))
                // A final newline opens one more, empty, line: VS Code numbers it.
                if i < text.length || isNewline(text.character(at: i - 1)) { starts.append(i) }
            }
            lineStarts = starts
            linesValid = true
        }
        return lineStarts
    }

    private func isNewline(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

    /// The 0-based line holding `location`.
    private func line(of location: Int) -> Int {
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let layout = tv.layoutManager, let container = tv.textContainer,
              tv.string.isEmpty == false || tv.isEditable else { return }
        let visible = tv.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let current = line(of: tv.selectedRange().location)
        let origin = convert(NSPoint.zero, from: tv).y + tv.textContainerOrigin.y
        let text = tv.string as NSString
        var index = line(of: chars.location)
        while index < lines.count, lines[index] <= NSMaxRange(chars) {
            let start = lines[index]
            let y: CGFloat
            if start < text.length {
                let glyph = layout.glyphIndexForCharacter(at: start)
                y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            } else {
                y = layout.extraLineFragmentRect.minY
            }
            label(index + 1, at: origin + y, current: index == current)
            index += 1
        }
    }

    private func label(_ number: Int, at y: CGFloat, current: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.numberFont, .foregroundColor: current ? Theme.activeLineNumber : Theme.lineNumber]
        let string = String(number) as NSString
        let size = string.size(withAttributes: attrs)
        let top = y + (Theme.lineHeight - size.height) / 2
        string.draw(at: NSPoint(x: ruleThickness - Self.trailing - size.width, y: top), withAttributes: attrs)
    }
}

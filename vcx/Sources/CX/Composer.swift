import AppKit
import SwiftUI
import ImageIO

final class ComposerWindow: NSWindow {
    var focusComposer: () -> Void = {}
    var chooseOption: (Int) -> Bool = { _ in false }
    private var clickStart: NSPoint?
    override func sendEvent(_ event: NSEvent) {
        // Key codes, not characters: the number row types symbols without Shift on AZERTY.
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty, attachedSheet == nil,
           let index = [18, 19, 20, 21, 23, 22, 26, 28, 25].firstIndex(of: event.keyCode) ?? [83, 84, 85, 86, 87, 88, 89, 91, 92].firstIndex(of: event.keyCode),
           (firstResponder as? NSText).map({ $0 is ComposerText ? $0.string.isEmpty : !$0.isEditable }) ?? true,
           chooseOption(index + 1) { return }
        if event.type == .keyDown, !(firstResponder is ComposerText), (firstResponder as? NSText)?.isEditable != true, attachedSheet == nil {
            if [36, 49, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                focusComposer(); return
            }
            // Arrows and function keys carry private-use characters (U+F700...) and keep scrolling the transcript.
            let typed = event.keyCode != 49 && event.modifierFlags.intersection([.command, .control]).isEmpty
                && event.characters?.unicodeScalars.first.map { ![.control, .privateUse].contains($0.properties.generalCategory) } == true
            let pasted = event.charactersIgnoringModifiers == "v" && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
            if typed || pasted {
                focusComposer()
                // The app focuses asynchronously; the key follows once the composer has it.
                if firstResponder is ComposerText { super.sendEvent(event) }
                else { DispatchQueue.main.async { [weak self] in if self?.firstResponder is ComposerText { self?.sendEvent(event) } } }
                return
            }
        }
        if event.type == .leftMouseDown { clickStart = event.clickCount == 1 ? convertPoint(toScreen: event.locationInWindow) : nil }
        super.sendEvent(event)
        // A click on a blank spot focuses the composer as Return does; a drag or a double click may be selecting text.
        // Text views track their own clicks, so a click inside one never reaches here as a mouse up.
        if event.type == .leftMouseUp, let start = clickStart {
            clickStart = nil
            let end = convertPoint(toScreen: event.locationInWindow)
            if hypot(end.x - start.x, end.y - start.y) < 4, !(firstResponder is ComposerText), (firstResponder as? NSText)?.isEditable != true,
               attachedSheet == nil { focusComposer() }
        }
    }
}

final class ImageChip: NSTextAttachment {
    let path: String
    let number: Int
    init(path: String, number: Int) {
        self.path = path; self.number = number
        super.init(data: nil, ofType: nil)
        attachmentCell = chipCell("[Image #\(number)]")
    }
    required init?(coder: NSCoder) { nil }
}

final class PasteChip: NSTextAttachment {
    let text: String
    let number: Int
    init(text: String, number: Int) {
        self.text = text; self.number = number
        super.init(data: nil, ofType: nil)
        attachmentCell = chipCell("[Paste #\(number)]")
    }
    required init?(coder: NSCoder) { nil }
}

// A command chosen in the composer: shows what was typed, runs `value` (hover shows it).
final class CommandChip: NSTextAttachment {
    let label: String
    let value: String
    init(label: String, value: String) {
        self.label = label; self.value = value
        super.init(data: nil, ofType: nil)
        attachmentCell = chipCell(label, fill: NSColor.black.withAlphaComponent(0.09))
    }
    required init?(coder: NSCoder) { nil }
}

extension NSAttributedString {
    // A leading command chip reads as the command it runs, a later one as the name typed.
    var commandText: String {
        var text = ""
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, _ in
            if let chip = value as? CommandChip { text += text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? chip.value : chip.label }
            else { text += (string as NSString).substring(with: range) }
        }
        return text
    }
}

private final class ChipCell: NSTextAttachmentCell {
    var padding: CGFloat = 0
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).descender) }
    // A chip that opens the message starts at the text's edge, without its left margin.
    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        var frame = super.cellFrame(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex)
        if charIndex == 0 { frame.size.width -= padding }
        return frame
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        var frame = cellFrame
        if charIndex == 0 { frame.origin.x -= padding; frame.size.width += padding }
        super.draw(withFrame: frame, in: controlView, characterIndex: charIndex, layoutManager: layoutManager)
    }
}

private func chipCell(_ title: String, fill: NSColor? = nil) -> NSTextAttachmentCell {
    let label = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.black])
    // A command chip hugs its letters like the purple tint does, so they sit where typed text would.
    let padding: CGFloat = fill == nil ? 6 : 0
    let image = NSImage(size: NSSize(width: label.size().width + 2 * padding, height: label.size().height), flipped: false) { rect in
        if let fill { fill.setFill(); rect.fill() }
        label.draw(at: NSPoint(x: padding, y: 0))
        return true
    }
    let cell = ChipCell(imageCell: image)
    cell.padding = padding
    return cell
}

private let commandWordPattern = try! NSRegularExpression(pattern: #"(?<![\w/:.\-])/([\w\-]+(?::[\w\-]+)*)(?![\w/\-]|[.:]\w)"#)
private let commandTint = NSColor(red: 0.43, green: 0.23, blue: 0.75, alpha: 0.16)

enum InputPiece { case text(String), image(String) }

func pastedPieces(_ source: String) -> [InputPiece] {
    let string = source as NSString
    let regex = try! NSRegularExpression(pattern: #"(?i)\.(?:png|jpe?g|gif|webp|bmp|tiff?)(?=[\s\"']|$)"#)
    var spans: [(NSRange, String)] = [], consumed = 0
    for match in regex.matches(in: source, range: NSRange(location: 0, length: string.length)) {
        let end = NSMaxRange(match.range)
        for start in consumed..<match.range.location {
            if start > 0 {
                guard let scalar = UnicodeScalar(string.character(at: start - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            }
            var candidate = string.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasPrefix("\"") || candidate.hasPrefix("'") { candidate.removeFirst() }
            candidate = candidate.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            if candidate.hasPrefix("file://"), let url = URL(string: candidate) { candidate = url.path }
            candidate = (candidate as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: candidate), NSImage(contentsOfFile: candidate) != nil {
                var length = end - start
                if end < string.length, [34, 39].contains(string.character(at: end)) { length += 1 }
                spans.append((NSRange(location: start, length: length), URL(fileURLWithPath: candidate).standardized.path))
                consumed = start + length
                break
            }
        }
    }
    var pieces: [InputPiece] = [], at = 0
    for (range, path) in spans {
        if range.location > at { pieces.append(.text(string.substring(with: NSRange(location: at, length: range.location - at)))) }
        pieces.append(.image(path)); at = NSMaxRange(range)
    }
    if at < string.length { pieces.append(.text(string.substring(from: at))) }
    return pieces
}

struct Composer: NSViewRepresentable {
    @ObservedObject var session: Session
    var hidingPlaceholder = false
    var willSubmit: (String, [String], ComposerSnapshot?) -> Void = { _, _, _ in }
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        let field = ComposerText(frame: .zero, textContainer: container)
        field.heldStorage = storage; field.session = session; field.delegate = context.coordinator
        field.hidingPlaceholder = hidingPlaceholder
        field.willSubmit = willSubmit
        field.isEditable = !session.frontendReplacing
        field.setDraft(session.draft)
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = field
        field.resized = { [weak field, coordinator = context.coordinator] in if let field { coordinator.measure(field) } }
        session.submitDraft = { [weak field] in field?.submit() }
        session.replaceInComposer = { [weak field] range, piece in
            guard let field, NSMaxRange(range) <= (field.string as NSString).length else { return false }
            field.insertPiece(piece, replacing: range); return true
        }
        session.focusComposer = { [weak field] in DispatchQueue.main.async { if let field { field.window?.makeFirstResponder(field) } } }
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let field = scroll.documentView as? ComposerText else { return }
        if field.hidingPlaceholder != hidingPlaceholder { field.hidingPlaceholder = hidingPlaceholder; field.needsDisplay = true }
        let asking = session.questionFlow?.done == false
        if field.asking != asking { field.asking = asking; field.needsDisplay = true }
        field.willSubmit = willSubmit
        field.isEditable = !session.frontendReplacing
        guard context.coordinator.revision != session.draftRevision else { return }
        context.coordinator.revision = session.draftRevision
        context.coordinator.syncing = true
        defer { context.coordinator.syncing = false }
        field.setDraft(session.draft)
        field.setSelectedRange(NSRange(location: session.draft.length, length: 0))
        field.needsDisplay = true
        context.coordinator.measure(field)
    }
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: Session
        var revision = 0
        var syncing = false
        init(_ session: Session) { self.session = session }
        func textDidChange(_ notification: Notification) {
            guard !syncing, let field = notification.object as? ComposerText, let storage = field.textStorage else { return }
            session.editDraft(NSAttributedString(attributedString: storage), refresh: false)
            session.updateCommands(storage.string, caret: field.selectedRange().location)
            measure(field)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !syncing, let field = notification.object as? ComposerText else { return }
            session.updateCommands(field.string, caret: field.selectedRange().location)
        }
        // A space after an exact command name locks it into a chip.
        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard text == " ", range.length == 0, !view.hasMarkedText(), let word = session.slashWord(view.string, caret: range.location) else { return true }
            let typed = (view.string as NSString).substring(with: word)
            guard let command = session.commandCatalog.first(where: { $0.name.caseInsensitiveCompare(typed) == .orderedSame || $0.insert.trimmingCharacters(in: .whitespaces) == typed }) else { return true }
            session.lockCommand(typed, command.insert.trimmingCharacters(in: .whitespaces), space: true, in: word)
            return false
        }
        func textView(_ view: NSTextView, shouldChangeTypingAttributes old: [String: Any], toAttributes new: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            new.filter { $0.key != .toolTip }
        }
        // Measured when the deferred update runs: comparing a fresh height with one still waiting to be set
        // dropped the last of two measures in one pass and left a wrapped line clipped.
        func measure(_ field: NSTextView) {
            DispatchQueue.main.async { [weak field, session] in
                guard let field, let manager = field.layoutManager, let container = field.textContainer else { return }
                manager.ensureLayout(for: container)
                let height = min(max(manager.usedRect(for: container).height, 24), 150).rounded(.up)
                if height != session.editorHeight { session.editorHeight = height }
            }
        }
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)), (view as? ComposerText)?.expandPaste() == true { return true }
            if session.commandQuery != nil {
                if selector == #selector(NSResponder.moveUp(_:)) { session.moveCommand(-1); return true }
                if selector == #selector(NSResponder.moveDown(_:)) { session.moveCommand(1); return true }
                if selector == #selector(NSResponder.insertTab(_:)) { return session.completeCommand() }
                if selector == #selector(NSResponder.cancelOperation(_:)) { session.dismissCommands(); return true }
            }
            if selector == #selector(NSResponder.moveUp(_:)), session.recallQueued() || session.movePromptHistory(-1) { return true }
            if selector == #selector(NSResponder.cancelOperation(_:)), session.restoreRecalled() { return true }
            if selector == #selector(NSResponder.moveDown(_:)), session.movePromptHistory(1) { return true }
            if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.intersection([.shift, .option]).isEmpty != false {
                if session.commandQuery != nil, !session.commandOptions.isEmpty {
                    if session.commandToken != nil { _ = session.completeCommand(); return true }
                    let selected = session.commandOptions[min(session.commandSelection, session.commandOptions.count - 1)]
                    if session.providerCommands.contains(selected) {
                        session.commandQuery = nil
                        Task { await session.command(selected.insert) }; return true
                    }
                    if selected.insert != view.string { _ = session.completeCommand(); return true }
                }
                session.commandQuery = nil
                (view as? ComposerText)?.submit(); return true
            }
            return false
        }
    }
}

struct ComposerSnapshot {
    let image: NSImage
    let bounds: CGRect
}

final class ComposerText: NSTextView {
    weak var session: Session?
    var hidingPlaceholder = false
    var asking = false
    var willSubmit: (String, [String], ComposerSnapshot?) -> Void = { _, _, _ in }
    var heldStorage: NSTextStorage?
    var resized: () -> Void = {}
    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        font = .monospacedSystemFont(ofSize: 12, weight: .regular); textColor = .black; insertionPointColor = .black
        drawsBackground = false; isRichText = true; importsGraphics = false; allowsUndo = true; usesFontPanel = false
        isAutomaticQuoteSubstitutionEnabled = false; isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false; isAutomaticSpellingCorrectionEnabled = false
        textContainerInset = .zero
        typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.black]
        isVerticallyResizable = true; isHorizontallyResizable = false; autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        setAccessibilityLabel("Message")
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { nil }
    func setDraft(_ draft: NSAttributedString) {
        textStorage?.setAttributedString(draft)
        textStorage?.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: NSRange(location: 0, length: draft.length))
        textColor = .black
        typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.black]
        draft.enumerateAttribute(.attachment, in: NSRange(location: 0, length: draft.length)) { value, range, _ in
            if let chip = value as? CommandChip { textStorage?.addAttribute(.toolTip, value: chip.value, range: range) }
        }
        highlightCommands()
    }
    // Words naming a command light up only when typed with "/"; display only, never stored.
    func highlightCommands() {
        guard let manager = layoutManager, let words = session?.commandWords else { return }
        let text = string as NSString, all = NSRange(location: 0, length: text.length)
        manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        for match in commandWordPattern.matches(in: string, range: all) where words.contains(text.substring(with: match.range(at: 1))) {
            manager.addTemporaryAttribute(.backgroundColor, value: commandTint, forCharacterRange: match.range)
        }
    }
    override func setFrameSize(_ size: NSSize) { let changed = size.width != frame.width; super.setFrameSize(size); if changed { resized() } }
    override func didChangeText() { highlightCommands(); super.didChangeText(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !hidingPlaceholder { NSAttributedString(string: asking ? "Press a number, or type your own answer…" : "Ask anything · / commands…", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.black.withAlphaComponent(0.6)]).draw(at: NSPoint(x: 5, y: 0)) }
    }
    override func paste(_ sender: Any?) { paste(from: .general) }
    @discardableResult func paste(from board: NSPasteboard) -> Bool {
        guard session?.frontendReplacing != true else { return false }
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let images = files.filter { NSImage(contentsOf: $0) != nil }
        if !images.isEmpty { for image in images { putImage(image.path) }; return true }
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff), data.count <= 32 * 1024 * 1024,
           let representation = NSBitmapImageRep(data: data), let png = representation.representation(using: .png, properties: [:]) {
            do {
                let directory = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/VCX/Attachments")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent(UUID().uuidString + ".png")
                try png.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                putImage(url.path); return true
            } catch { session?.notice("Could not attach the image: " + error.localizedDescription); return false }
        }
        guard let text = board.string(forType: .string) else { return false }
        for piece in pastedPieces(text) {
            switch piece {
            case .text(let words) where words.count < 20 || words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: insertText(words, replacementRange: selectedRange())
            case .text(let words): putPaste(words)
            case .image(let path): putImage(path)
            }
        }
        return true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { paste(from: sender.draggingPasteboard) }
    func putImage(_ path: String) {
        guard session?.frontendReplacing != true else { return }
        insertPiece(NSAttributedString(attachment: ImageChip(path: path, number: chips(ImageChip.self) + 1)))
    }
    func putPaste(_ text: String) {
        guard session?.frontendReplacing != true else { return }
        let chip = PasteChip(text: text, number: chips(PasteChip.self) + 1)
        insertPiece(NSAttributedString(attachment: chip))
    }
    func expandPaste() -> Bool {
        let caret = selectedRange()
        guard caret.length == 0, caret.location > 0,
              let chip = textStorage?.attribute(.attachment, at: caret.location - 1, effectiveRange: nil) as? PasteChip else { return false }
        insertPiece(NSAttributedString(string: chip.text), replacing: NSRange(location: caret.location - 1, length: 1))
        return true
    }
    private func chips<Chip>(_ kind: Chip.Type) -> Int {
        var count = 0
        textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage?.length ?? 0)) { value, _, _ in if value is Chip { count += 1 } }
        return count
    }
    func insertPiece(_ value: NSAttributedString, replacing: NSRange? = nil) {
        let piece = NSMutableAttributedString(attributedString: value)
        var attributes = typingAttributes; attributes.removeValue(forKey: .attachment)
        piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
        let range = replacing ?? selectedRange()
        guard shouldChangeText(in: range, replacementString: piece.string) else { return }
        textStorage?.replaceCharacters(in: range, with: piece)
        setSelectedRange(NSRange(location: range.location + piece.length, length: 0))
        typingAttributes = attributes; didChangeText()
    }
    override func mouseDown(with event: NSEvent) {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs else { return super.mouseDown(with: event) }
        let index = manager.characterIndexForGlyph(at: glyph)
        if index < storage.length, let chip = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ImageChip,
           manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) { session?.preview = chip.path; return }
        super.mouseDown(with: event)
    }
    func message() -> (String, [String]) {
        guard let storage = textStorage else { return ("", []) }
        var text = "", images: [String] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let chip = value as? ImageChip { images.append(chip.path) }
            else if let chip = value as? PasteChip { text += chip.text }
            else if let chip = value as? CommandChip { text += text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? chip.value : chip.label }
            else if value == nil { text += (storage.string as NSString).substring(with: range) }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), images)
    }
    func sendSnapshot() -> ComposerSnapshot? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        manager.ensureLayout(for: container)
        let visible = visibleRect
        let glyphs = manager.glyphRange(forBoundingRect: visible.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: container)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).intersection(visible).integral
        guard !rect.isEmpty, let bitmap = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return ComposerSnapshot(image: image, bounds: rect.offsetBy(dx: -visible.minX, dy: -visible.minY))
    }
    func submit() {
        guard let session, !session.frontendReplacing else { return }
        let (text, images) = message()
        if session.questionFlow?.done == false, !text.hasPrefix("/") {
            session.answerQuestion(text)
            if !text.isEmpty { session.editDraft(NSAttributedString(string: "")) }
            return
        }
        let draft = NSAttributedString(attributedString: session.draft), generation = session.draftGeneration
        if session.ready, !session.changing, !text.hasPrefix("/"), !text.isEmpty || !images.isEmpty { willSubmit(text, images, sendSnapshot()) }
        Task { await session.send(text: text, images: images, expectedDraft: draft, expectedGeneration: generation) }
    }
}

func thumbnail(_ path: String, size: Int = 360) -> NSImage? {
    let source: CGImageSource?
    if path.hasPrefix("data:"), let comma = path.firstIndex(of: ","), let data = Data(base64Encoded: String(path[path.index(after: comma)...])) { source = CGImageSourceCreateWithData(data as CFData, nil) }
    else { source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) }
    guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: .zero)
}

func agentImage(_ path: String) throws -> (Data, String) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count <= 20 * 1024 * 1024 else { throw CXError(message: "Image is larger than 20 MB. Use a smaller image.") }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String? else { throw CXError(message: "This file is not a supported image.") }
    if let media = ["public.png": "image/png", "public.jpeg": "image/jpeg", "com.compuserve.gif": "image/gif", "org.webmproject.webp": "image/webp"][type] { return (data, media) }
    guard let image = thumbnail(path, size: 2048), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw CXError(message: "Could not convert this image to PNG.") }
    return (png, "image/png")
}

func draftContent(_ draft: NSAttributedString) -> [JSON] {
    var pieces: [JSON] = []
    draft.enumerateAttribute(.attachment, in: NSRange(location: 0, length: draft.length)) { value, range, _ in
        if let chip = value as? ImageChip { pieces.append(["type": "localImage", "path": chip.path]) }
        else if let chip = value as? PasteChip { pieces.append(["type": "paste", "text": chip.text, "number": chip.number]) }
        // "text" keeps the runnable command, so a worker on an older build restores it as plain text.
        else if let chip = value as? CommandChip { pieces.append(["type": "command", "text": chip.value, "label": chip.label]) }
        else if value == nil { pieces.append(["type": "text", "text": (draft.string as NSString).substring(with: range)]) }
    }
    return pieces
}

// A runtime worker started before paste chips existed echoes them back as plain text: same draft.
func plainDraftContent(_ pieces: [JSON]) -> [JSON] {
    pieces.reduce(into: []) { plain, piece in
        let piece: JSON = ["paste", "command"].contains(piece["type"] as? String) ? ["type": "text", "text": piece["text"] as? String ?? ""] : piece
        if piece["type"] as? String == "text", let last = plain.last, last["type"] as? String == "text" {
            plain[plain.count - 1]["text"] = (last["text"] as? String ?? "") + (piece["text"] as? String ?? "")
        } else { plain.append(piece) }
    }
}

import AppKit
import SwiftUI
import ImageIO

final class ComposerWindow: NSWindow {
    var focusComposer: () -> Void = {}
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, [36, 49, 76].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           !(firstResponder is ComposerText), (firstResponder as? NSText)?.isEditable != true,
           attachedSheet == nil {
            focusComposer(); return
        }
        super.sendEvent(event)
    }
}

final class ImageChip: NSTextAttachment {
    let path: String
    let number: Int
    init(path: String, number: Int) {
        self.path = path; self.number = number
        super.init(data: nil, ofType: nil)
        let label = NSAttributedString(string: "Image \(number)", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black])
        let image = NSImage(size: NSSize(width: label.size().width + 42, height: 18), flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 0), xRadius: 6, yRadius: 6).fill()
            NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.black]))?.draw(in: NSRect(x: 9, y: 3, width: 13, height: 12))
            label.draw(at: NSPoint(x: 27, y: (18 - label.size().height) / 2))
            return true
        }
        image.size = NSSize(width: image.size.width * 13 / 18, height: 13)
        attachmentCell = Cell(imageCell: image)
    }
    required init?(coder: NSCoder) { nil }
    private final class Cell: NSTextAttachmentCell {
        override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -2) }
    }
}

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
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        let field = ComposerText(frame: .zero, textContainer: container)
        field.heldStorage = storage; field.session = session; field.delegate = context.coordinator
        field.isEditable = !session.frontendReplacing
        field.setDraft(session.draft)
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = field
        field.resized = { [weak field, coordinator = context.coordinator] in if let field { coordinator.measure(field) } }
        session.submitDraft = { [weak field] in field?.submit() }
        session.focusComposer = { [weak field] in DispatchQueue.main.async { if let field { field.window?.makeFirstResponder(field) } } }
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let field = scroll.documentView as? ComposerText else { return }
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
            guard let field = notification.object as? ComposerText, let storage = field.textStorage else { return }
            session.editDraft(NSAttributedString(attributedString: storage), refresh: false)
            session.updateCommands(storage.string, caret: field.selectedRange().location)
            measure(field)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !syncing, let field = notification.object as? ComposerText else { return }
            session.updateCommands(field.string, caret: field.selectedRange().location)
        }
        func measure(_ field: NSTextView) {
            guard let manager = field.layoutManager, let container = field.textContainer else { return }
            manager.ensureLayout(for: container)
            let height = min(max(manager.usedRect(for: container).height, 24), 150).rounded(.up)
            if height != session.editorHeight { DispatchQueue.main.async { self.session.editorHeight = height } }
        }
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if session.commandQuery != nil {
                if selector == #selector(NSResponder.moveUp(_:)) { session.moveCommand(-1); return true }
                if selector == #selector(NSResponder.moveDown(_:)) { session.moveCommand(1); return true }
                if selector == #selector(NSResponder.insertTab(_:)) { return session.completeCommand() }
                if selector == #selector(NSResponder.cancelOperation(_:)) { session.dismissCommands(); return true }
            }
            if selector == #selector(NSResponder.moveUp(_:)), session.movePromptHistory(-1) { return true }
            if selector == #selector(NSResponder.moveDown(_:)), session.movePromptHistory(1) { return true }
            if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.intersection([.shift, .option]).isEmpty != false {
                if session.commandQuery != nil, !session.commandOptions.isEmpty {
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

final class ComposerText: NSTextView {
    weak var session: Session?
    var heldStorage: NSTextStorage?
    var resized: () -> Void = {}
    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        font = .monospacedSystemFont(ofSize: 16.5, weight: .regular); textColor = .black; insertionPointColor = .black
        drawsBackground = false; isRichText = true; importsGraphics = false; allowsUndo = true; usesFontPanel = false
        textContainerInset = .zero
        typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 16.5, weight: .regular), .foregroundColor: NSColor.black]
        isVerticallyResizable = true; isHorizontallyResizable = false; autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        setAccessibilityLabel("Message")
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { nil }
    func setDraft(_ draft: NSAttributedString) {
        textStorage?.setAttributedString(draft)
        textStorage?.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 16.5, weight: .regular), range: NSRange(location: 0, length: draft.length))
        textColor = .black
        typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 16.5, weight: .regular), .foregroundColor: NSColor.black]
    }
    override func setFrameSize(_ size: NSSize) { let changed = size.width != frame.width; super.setFrameSize(size); if changed { resized() } }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty { NSAttributedString(string: "Ask anything · / commands…", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 16.5, weight: .regular), .foregroundColor: NSColor.black.withAlphaComponent(0.6)]).draw(at: NSPoint(x: 5, y: 0)) }
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
            switch piece { case .text(let words): insertText(words, replacementRange: selectedRange()); case .image(let path): putImage(path) }
        }
        return true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { paste(from: sender.draggingPasteboard) }
    func putImage(_ path: String) {
        guard session?.frontendReplacing != true else { return }
        var count = 0
        textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage?.length ?? 0)) { value, _, _ in if value is ImageChip { count += 1 } }
        let piece = NSMutableAttributedString(attachment: ImageChip(path: path, number: count + 1))
        piece.addAttributes(typingAttributes, range: NSRange(location: 0, length: piece.length))
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: piece.string) else { return }
        textStorage?.replaceCharacters(in: range, with: piece)
        setSelectedRange(NSRange(location: range.location + piece.length, length: 0)); didChangeText()
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
            else if value == nil { text += (storage.string as NSString).substring(with: range) }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), images)
    }
    func submit() {
        guard let session, !session.frontendReplacing else { return }
        let (text, images) = message()
        Task { await session.send(text: text, images: images) }
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
        else if value == nil { pieces.append(["type": "text", "text": (draft.string as NSString).substring(with: range)]) }
    }
    return pieces
}

import AppKit
import TextCore

enum Style {
    static let fontSize: CGFloat = 12
    static let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    static let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    static let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]

    static func color(_ kind: TokenKind) -> NSColor {
        switch kind {
        case .comment: return .systemGray
        case .string: return .systemRed
        case .number: return .systemPurple
        case .keyword: return .systemPink
        case .key, .tag: return .systemBlue
        case .heading: return .systemOrange
        }
    }
}

/// One open file: its text (kept while another file is shown), its own undo stack, and a watcher
/// that reloads it when it changes on disk and has no unsaved edits.
final class Document: NSObject, NSTextStorageDelegate {
    /// Above this the file is shown uncolored, so opening a big log stays instant.
    static let maxColoredBytes = 2 * 1024 * 1024
    /// Writes come in bursts (a log being appended to, an editor saving): one reload per burst.
    static let reloadDelay: DispatchTimeInterval = .milliseconds(100)

    let url: URL
    let storage = NSTextStorage()
    let undo = UndoManager()
    var encoding = String.Encoding.utf8
    var dirty = false { didSet { if dirty != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    var willReload: (() -> Void)?
    var didReload: (() -> Void)?
    private var highlighter: Highlighter?
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadPending = false
    private var loading = false

    var name: String { url.lastPathComponent }
    var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }

    init(url: URL) throws {
        self.url = url
        super.init()
        storage.delegate = self
        try load(FileText.read(url))
        watch()
    }

    deinit { watcher?.cancel() }

    private func load(_ file: (String, String.Encoding)) {
        let (text, encoding) = file
        self.encoding = encoding
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let language = Language.detect(fileName: name, firstLine: FileText.firstLine(text))
        highlighter = size <= Self.maxColoredBytes ? Highlighter.shared(language) : nil
        loading = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        color(NSRange(location: 0, length: storage.length))
        storage.endEditing()
        loading = false
    }

    func save() throws {
        encoding = try FileText.write(storage.string, to: url, encoding: encoding)
        dirty = false
    }

    private func color(_ range: NSRange) {
        storage.setAttributes(Style.base, range: range)
        guard let highlighter, highlighter.colors else { return }
        for token in highlighter.tokens(in: storage.string, range: range) {
            storage.addAttribute(.foregroundColor, value: Style.color(token.kind), range: token.range)
            if token.kind == .heading { storage.addAttribute(.font, value: Style.bold, range: token.range) }
        }
    }

    // ponytail: only the edited paragraphs are recolored, so typing `/*` colors the lines below
    // only once the file is reopened; color the whole file on edit if that ever bothers.
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard !loading, editedMask.contains(.editedCharacters) else { return }
        color((storage.string as NSString).paragraphRange(for: editedRange))
    }

    private func watch() {
        watcher?.cancel()
        watcher = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, unowned source] in
            // An atomic save (ours or another editor's) swaps the file: watch the new one.
            let swapped = !source.data.isDisjoint(with: [.delete, .rename])
            self?.scheduleReload(rewatch: swapped)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleReload(rewatch: Bool) {
        if rewatch { watcher?.cancel(); watcher = nil }
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reloadDelay) { [weak self] in
            guard let self else { return }
            reloadPending = false
            if watcher == nil { watch() }
            reloadFromDisk()
        }
    }

    private func reloadFromDisk() {
        guard !dirty, let file = try? FileText.read(url), file.0 != storage.string else { return }
        willReload?()
        undo.removeAllActions()
        load(file)
        didReload?()
    }
}

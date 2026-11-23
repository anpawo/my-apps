import AppKit
import TextCore

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
    private(set) var language = Language.plain
    private(set) var modified = Date.distantPast
    private var highlighter: Highlighter?
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadPending = false
    private var loading = false

    var name: String { url.lastPathComponent }

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
        readModified()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        language = Language.detect(fileName: name, firstLine: FileText.firstLine(text))
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
        readModified()
        dirty = false
    }

    private func readModified() {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        modified = (try? fresh.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
    }

    private func color(_ range: NSRange) {
        storage.setAttributes(Theme.base, range: range)
        guard let highlighter, highlighter.colors else { return }
        for token in highlighter.tokens(in: storage.string, range: range) {
            storage.addAttribute(.foregroundColor, value: Theme.color(token), range: token.range)
            if let font = Theme.font(token) { storage.addAttribute(.font, value: font, range: token.range) }
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

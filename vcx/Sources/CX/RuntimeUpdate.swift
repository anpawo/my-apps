import AppKit
import Darwin

struct FrontendReplacementProcess {
    let pid: pid_t
    let isTerminated: () -> Bool
    let terminate: () -> Void

    init(_ application: NSRunningApplication) {
        pid = application.processIdentifier
        isTerminated = { application.isTerminated }
        terminate = { application.forceTerminate() }
    }

    init(_ process: Process) {
        pid = process.processIdentifier
        isTerminated = { !process.isRunning }
        terminate = { if process.isRunning { process.terminate() } }
    }
}

@MainActor
enum RuntimeUpdate {
    static let openNotification = Notification.Name("com.mr.vcx.open")
    static let updateNotification = Notification.Name("com.mr.vcx.update")
    static let readyNotification = Notification.Name("com.mr.vcx.ready")
    static var installed: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Vibe Code X.app") }

    static func writeTicket(_ value: JSON, suffix: String, maximumBytes: Int = 1_048_576) throws -> URL {
        try RuntimeIdentity.prepareDirectory()
        let file = RuntimeIdentity.directory.appendingPathComponent(UUID().uuidString + suffix)
        let data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= maximumBytes else { throw CXError(message: "Frontend handoff is too large.") }
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CXError(message: "Cannot save frontend handoff.") }
        return file
    }

    static func readTicket(_ path: String, suffix: String, maximumBytes: Int = 1_048_576) throws -> JSON {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        var info = stat()
        guard file.deletingLastPathComponent() == RuntimeIdentity.directory.standardizedFileURL,
              file.lastPathComponent.hasSuffix(suffix), lstat(file.path, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= maximumBytes else { throw CXError(message: "Unsafe frontend handoff file.") }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CXError(message: "Cannot read frontend handoff.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
              let value = try JSONSerialization.jsonObject(with: handle.readDataToEndOfFile()) as? JSON else { throw CXError(message: "Invalid frontend handoff.") }
        return value
    }

    static func publish(manual: Bool = false) throws {
        try RuntimeIdentity.prepareDirectory()
        if manual { try write(RuntimeIdentity.build, "manual-build") }
        else { try? FileManager.default.removeItem(at: RuntimeIdentity.directory.appendingPathComponent("manual-build")) }
        try write(RuntimeIdentity.build, "installed-build")
        DistributedNotificationCenter.default().postNotificationName(updateNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // Any session or build may send this; it names the installed build, not the sender's own.
    static func requestUpdate() throws {
        guard let installed = read("installed-build") else { throw CXError(message: "No installed VCX build has been published.") }
        try write(installed, "update-request")
        DistributedNotificationCenter.default().postNotificationName(updateNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // The build running workers and windows should move to: a build installed with --manual waits for --update-now.
    static func pendingBuild() -> String? {
        guard let installed = read("installed-build"), installed != RuntimeIdentity.build else { return nil }
        return read("manual-build") == installed && read("update-request") != installed ? nil : installed
    }

    // Changes with every --update-now, so a worker retries a build it already failed to move to.
    static var requestStamp: String {
        let date = try? FileManager.default.attributesOfItem(atPath: RuntimeIdentity.directory.appendingPathComponent("update-request").path)[.modificationDate] as? Date
        return date.map { String($0.timeIntervalSince1970) } ?? ""
    }

    private static func read(_ name: String) -> String? { try? String(contentsOf: RuntimeIdentity.directory.appendingPathComponent(name), encoding: .utf8) }

    private static func write(_ value: String, _ name: String) throws {
        let file = RuntimeIdentity.directory.appendingPathComponent(name)
        try Data(value.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func acknowledge(_ ticket: String) throws {
        let file = URL(fileURLWithPath: ticket + ".ready.json")
        let data = try JSONSerialization.data(withJSONObject: ["pid": getpid()])
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CXError(message: "Cannot acknowledge frontend replacement.") }
        DistributedNotificationCenter.default().postNotificationName(readyNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func lockFrontend() throws -> Int32? {
        try RuntimeIdentity.prepareDirectory()
        let descriptor = Darwin.open(RuntimeIdentity.directory.appendingPathComponent("frontend.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var info = stat()
        guard descriptor >= 0 else { throw CXError(message: "Cannot lock frontend ownership.") }
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor); throw CXError(message: "Unsafe frontend ownership lock.")
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
        Darwin.close(descriptor)
        return nil
    }

    static func forward(_ options: LaunchOptions) throws {
        var value: JSON = ["cwd": options.cwd, "prompt": options.prompt, "focus": options.focus]
        value["resume"] = options.resume
        _ = try writeTicket(value, suffix: ".open.json")
        DistributedNotificationCenter.default().postNotificationName(openNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        let children = view.subviews.compactMap { scrollView(in: $0) }
        let own = (view as? NSScrollView).flatMap { $0.documentView is ComposerText ? nil : $0 }
        // The widest: the sidebar's scroll view is taller than the transcript's.
        return (children + [own].compactMap { $0 }).max { $0.bounds.width < $1.bounds.width }
    }

    static func composer(in view: NSView?) -> ComposerText? {
        guard let view else { return nil }
        return (view as? ComposerText) ?? view.subviews.lazy.compactMap { composer(in: $0) }.first
    }

    static func state(window: NSWindow, session: Session) -> JSON {
        let selection = composer(in: window.contentView)?.selectedRange() ?? NSRange(location: 0, length: 0)
        var state: JSON = ["frame": NSStringFromRect(window.frame), "scrollY": scrollView(in: window.contentView)?.contentView.bounds.origin.y ?? 0,
                           "follow": session.follow.attached, "details": session.details, "selection": [selection.location, selection.length]]
        // The exchange crossing the top edge: the same offset shows other rows once a new window estimates the rows above.
        if let top = session.exchangeTops.filter({ $0.value <= 0 }).max(by: { $0.value < $1.value }) {
            state["anchor"] = top.key.uuidString; state["anchorTop"] = Double(top.value)
        }
        return state
    }

    // Before the conversation arrives too: a window still following sends its first rows to the end after the restored scroll.
    static func adopt(_ state: JSON, session: Session) {
        if let follow = state["follow"] as? Bool { session.follow.attached = follow }
        if let details = state["details"] as? Bool { session.details = details }
    }

    static func restore(_ state: JSON, window: NSWindow, session: Session) {
        adopt(state, session: session)
        DispatchQueue.main.async {
            window.contentView?.layoutSubtreeIfNeeded()
            if let selection = state["selection"] as? [Int], selection.count == 2,
               selection[0] >= 0, selection[1] >= 0, selection[0] + selection[1] <= session.draft.length {
                composer(in: window.contentView)?.setSelectedRange(NSRange(location: selection[0], length: selection[1]))
            }
            if !session.follow.attached, let y = state["scrollY"] as? Double, let scroll = scrollView(in: window.contentView) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height))))
                scroll.reflectScrolledClipView(scroll.contentView)
                if let anchor = (state["anchor"] as? String).flatMap({ UUID(uuidString: $0) }), let top = state["anchorTop"] as? Double, let jump = session.scrollToExchange {
                    jump(anchor)
                    // A timer, as in land(): SwiftUI has not applied the jump by the next main-queue block.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        window.contentView?.layoutSubtreeIfNeeded()
                        guard let now = session.exchangeTops[anchor] else { return }
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y + now - top))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                }
            }
        }
    }
}

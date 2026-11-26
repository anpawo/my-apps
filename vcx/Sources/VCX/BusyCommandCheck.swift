import AppKit
import SwiftUI

// The /model menus used while a turn runs, in a window attached to a real runtime worker (the path the app uses).
@MainActor
enum BusyCommandCheck {
    private static let settleNanoseconds: UInt64 = 300_000_000

    static func run() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "vcx-busy-command-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard mkfifo(directory.appendingPathComponent("release-tool").path, 0o600) == 0 else { throw VCXError(message: "Cannot create the tool gate.") }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/runtime_peer.py")
        let peer = Bundle.main.url(forResource: "runtime_peer", withExtension: "py") ?? source
        let command = directory.appendingPathComponent("command.json")
        try JSONSerialization.data(withJSONObject: ["/usr/bin/python3", peer.path, directory.path]).write(to: command)
        let socket = directory.appendingPathComponent("worker.sock").path
        let worker = Process()
        worker.executableURL = RuntimeIdentity.executable
        worker.arguments = ["--runtime-worker", socket, "--runtime-test", "--runtime-fixture-command", command.path]
        worker.environment = ProcessInfo.processInfo.environment.merging(["VCX_RUNTIME_HOME": directory.path, "VCX_CONFIG_HOME": directory.appendingPathComponent("config").path]) { _, new in new }
        worker.standardInput = FileHandle.nullDevice; worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
        try worker.run()
        defer { worker.terminate() }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<500 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw VCXError(message: "Busy command fixture timed out.")
        }
        try await wait { FileManager.default.fileExists(atPath: socket) }
        let session = Session(cwd: directory.path, stateDirectory: directory.appendingPathComponent("frontend-state"))
        let client = RuntimeClient(session: session, cwd: directory.path, socketPath: socket)
        session.runtimeClient = client
        defer { client.close(); session.close() }
        try await client.connect(resume: nil)
        try await wait { session.ready }
        await session.send(text: "Start a long turn", images: [])
        try await wait { session.busy }
        let host = NSHostingView(rootView: VCXView(session: session, sending: SendAnimation()))
        host.sizingOptions = []; host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(x: 0, y: 0, width: 1120, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: settleNanoseconds)
        guard let field = editor(host) else { throw VCXError(message: "Composer missing from the busy fixture.") }
        for character in "/model" { field.insertText(String(character), replacementRange: field.selectedRange()) }
        // Return on /model, on the current provider, on its model, then on its effort.
        let expected = ["/model ", "/model codex ", "/model codex fixture-model ", nil]
        for query in expected {
            field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try await wait { session.commandQuery == query && (query == nil || !session.commandOptions.isEmpty) }
        }
        try await wait { session.rows.last?.items.last?.text.contains("Model change queued") == true }
        print("ok: the model and effort menus open during a turn and the final choice is queued with a notice")
    }

    private static func editor(_ view: NSView) -> ComposerText? {
        (view as? ComposerText) ?? view.subviews.lazy.compactMap(editor).first
    }
}

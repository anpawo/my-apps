import AppKit
import SwiftUI

// A command from a reply, run in place on a pseudo-terminal: sudo and anything else that reads a tty can ask, and a
// prompt typed with echo off (a password) goes from a SecureField straight to the tty, never to the agent, a log or disk.
let shellLanguages: Set<String> = ["bash", "sh", "zsh", "shell", "console", "fish", "terminal"]
let runScheme = "vcx-run"

func runnable(_ code: String, language: String) -> Bool {
    shellLanguages.contains(language.lowercased()) || code.trimmingCharacters(in: .whitespaces).hasPrefix("sudo ")
}

// Inline `sudo …` spans become links that open the run panel: he cannot type a password into the agent's shell.
func runLinks(_ text: AttributedString) -> AttributedString {
    var text = text
    for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true && run.link == nil {
        let command = String(text[run.range].characters)
        guard command.hasPrefix("sudo "), let url = runURL(command) else { continue }
        text[run.range].link = url
    }
    return text
}

func runURL(_ command: String) -> URL? {
    var parts = URLComponents(); parts.scheme = runScheme; parts.path = command
    return parts.url
}

func runURLCommand(_ url: URL) -> String? {
    url.scheme == runScheme ? URLComponents(url: url, resolvingAgainstBaseURL: false)?.path : nil
}

private struct RunCommandKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }
extension EnvironmentValues { var runCommand: ((String) -> Void)? { get { self[RunCommandKey.self] } set { self[RunCommandKey.self] = newValue } } }

// Carriage returns redraw a line (progress bars) and escape sequences colour it: the panel keeps the last drawing, plain.
func terminalText(_ raw: String) -> String {
    let plain = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
    return plain.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        .map { expandTabs($0.components(separatedBy: "\r").last(where: { !$0.isEmpty }) ?? "") }.joined(separator: "\n")
        .trimmingCharacters(in: .newlines)
}

// A terminal puts a tab's next column on a multiple of 8; SwiftUI Text has no such stops, so ls columns zigzag.
let tabStop = 8
func expandTabs(_ line: String) -> String {
    guard line.contains("\t") else { return line }
    var result = ""
    for character in line {
        if character == "\t" { result += String(repeating: " ", count: tabStop - result.count % tabStop) } else { result.append(character) }
    }
    return result
}

@MainActor
final class CommandRun: ObservableObject, Identifiable {
    enum State: Equatable { case ready, running, finished(Int32) }
    let command: String, directory: String
    @Published private(set) var state = State.ready
    @Published private(set) var output = ""
    @Published private(set) var hidden = false
    private var raw = ""
    private var master: Int32 = -1, pid: pid_t = 0
    static let outputLimit = 200_000

    init(command: String, directory: String) { self.command = command; self.directory = directory }

    func start() {
        guard state == .ready else { return }
        var environment = agentEnvironment(); environment["TERM"] = "dumb"
        // Built before the fork: the child may only call async-signal-safe functions until execve.
        let words = ["/bin/zsh", "-c", command]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        let folder = strdup(directory)
        defer { (argv + envp + [folder]).forEach { free($0) } }
        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, nil)
        if child == 0 { _ = chdir(folder); execve(argv[0], argv, envp); _exit(127) }
        guard child > 0 else { output = "Could not open a terminal: " + String(cString: strerror(errno)); state = .finished(-1); return }
        master = fd; pid = child; state = .running
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                var settings = termios(); tcgetattr(fd, &settings)
                let chunk = String(decoding: buffer[0..<count], as: UTF8.self), echo = settings.c_lflag & tcflag_t(ECHO) != 0
                DispatchQueue.main.async { self?.received(chunk, echo: echo) }
            }
            var status: Int32 = 0
            waitpid(child, &status, 0)
            close(fd)
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async { self?.finished(code) }
        }
    }

    private func received(_ chunk: String, echo: Bool) {
        raw += chunk
        if raw.count > Self.outputLimit { raw = String(raw.suffix(Self.outputLimit)) }
        output = terminalText(raw); hidden = !echo
    }

    private func finished(_ code: Int32) { master = -1; hidden = false; state = .finished(code) }

    // The typed bytes are zeroed once written; a Swift String cannot be, so the field's own copy is cleared by its caller.
    func send(_ line: String) {
        guard state == .running, master >= 0 else { return }
        var bytes = Array(line.utf8) + [10]
        _ = bytes.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
        bytes.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) }
    }

    // forkpty made the child a session leader: the hangup reaches its whole group, sudo relays it to root's side.
    func stop() { if state == .running { kill(-pid, SIGHUP) } }
}

struct RunPanel: View {
    @ObservedObject var run: CommandRun
    let close: () -> Void
    @State private var line = ""
    @FocusState private var focused: Bool
    private let mono = Font.system(size: 12, design: .monospaced)
    static let outputHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(accent)
                Text(title)
                Spacer()
                if run.state == .running { Button("Stop") { run.stop() }.buttonStyle(.reactive(RoundedRectangle(cornerRadius: 5), outset: 4)).help("Send a hangup to the command") }
                else { Button(run.state == .ready ? "Cancel" : "Close") { close() }.buttonStyle(.reactive(RoundedRectangle(cornerRadius: 5), outset: 4)).keyboardShortcut(.cancelAction) }
            }.font(.system(size: 11, weight: .semibold)).foregroundStyle(.black.opacity(0.6))
            Text(run.command).font(mono.weight(.medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !run.output.isEmpty {
                ScrollView {
                    Text(run.output).font(mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.defaultScrollAnchor(.bottom).frame(maxHeight: Self.outputHeight).fixedSize(horizontal: false, vertical: true)
                .background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            switch run.state {
            case .ready:
                HStack {
                    Text("Runs in \(run.directory) on its own terminal").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Run") { run.start(); focused = true }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction)
                }
            case .running:
                Group {
                    if run.hidden { SecureField("Password (stays in VCX, never sent to the agent), then Return", text: $line) }
                    else { TextField("Input for the command, then Return", text: $line) }
                }.textFieldStyle(.roundedBorder).font(mono).focused($focused)
                .onSubmit { run.send(line); line = ""; focused = true }
                .onAppear { focused = true }
            case .finished:
                EmptyView()
            }
        }.transition(.opacity)
        .onChange(of: run.hidden) { _, _ in line = ""; focused = true }
        .onDisappear { line = "" }
    }

    private var title: String {
        switch run.state {
        case .ready: return "Run this command?"
        case .running: return run.hidden ? "Running · the command asks for a password" : "Running"
        case .finished(let code): return code == 0 ? "Done · exit 0" : "Failed · exit \(code)"
        }
    }
}

extension Session {
    // A running command keeps the panel: a second click never takes the tty from under a password prompt.
    func offerRun(_ command: String) {
        if run?.state == .running { return }
        run = CommandRun(command: command, directory: cwd)
    }
}

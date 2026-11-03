import SwiftUI
import AppKit
import Darwin

struct Account: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var provider: String
    var home: String?
    var enabled = true
}

struct Preferences: Codable {
    var provider = "auto"
    var accounts = [Account(id: "claude-default", name: "Default Claude", provider: "claude"), Account(id: "codex-default", name: "Default Codex", provider: "codex")]
    var limits: [String: Double] = [:]
    var qwenProxy = ""
    var qwenURL = "http://localhost:11434/api/chat"
    var qwenModel = "qwen3-8b-abl"
    var qwenVisionModel = "qwen3-vl:4b-instruct"
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VCX_CONFIG_HOME"] ?? NSHomeDirectory() + "/Library/Application Support/VCX")
    @Published var value: Preferences
    @Published var error = ""
    @Published var signingIn = false
    @Published var loginMessage = ""
    private var login: Process?
    private var saved = Preferences()
    private let url = Settings.directory.appendingPathComponent("settings.json")
    init() {
        value = Self.read(url)
        saved = value
    }
    private static func read(_ url: URL) -> Preferences {
        let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences()))) as? JSON ?? [:]
        let stored = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? JSON ?? [:]
        return (try? JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: defaults.merging(stored) { _, value in value }))) ?? Preferences()
    }
    func reload() { value = Self.read(url); saved = value }
    func save() { persist { _ in } }
    func updateLimit(account: String, reset: Double) { persist { $0.limits[account] = reset } }
    private func persist(_ update: (inout Preferences) -> Void) {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = Darwin.open(Self.directory.appendingPathComponent("settings.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CXError(message: "Could not lock shared settings.") }
            defer { flock(fd, LOCK_UN); Darwin.close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw CXError(message: "Could not lock shared settings.") }
            var latest = Self.read(url)
            if value.provider != saved.provider { latest.provider = value.provider }
            for account in value.accounts {
                guard let before = saved.accounts.first(where: { $0.id == account.id }) else {
                    if !latest.accounts.contains(where: { $0.id == account.id }) { latest.accounts.append(account) }
                    continue
                }
                if let index = latest.accounts.firstIndex(where: { $0.id == account.id }) {
                    if account.name != before.name { latest.accounts[index].name = account.name }
                    if account.enabled != before.enabled { latest.accounts[index].enabled = account.enabled }
                }
            }
            if value.qwenURL != saved.qwenURL { latest.qwenURL = value.qwenURL }
            if value.qwenProxy != saved.qwenProxy { latest.qwenProxy = value.qwenProxy }
            if value.qwenModel != saved.qwenModel { latest.qwenModel = value.qwenModel }
            if value.qwenVisionModel != saved.qwenVisionModel { latest.qwenVisionModel = value.qwenVisionModel }
            update(&latest)
            try JSONEncoder().encode(latest).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            value = latest; saved = latest; error = ""
        } catch { self.error = error.localizedDescription }
    }
    var candidates: [Account] {
        ["claude", "codex", "qwen"].filter { value.provider == "auto" || value.provider == $0 }.flatMap { provider in
            provider == "qwen" ? [Account(id: "qwen", name: "Qwen", provider: "qwen")] : value.accounts.filter { $0.provider == provider && $0.enabled }
        }
    }
    func addProfile(provider: String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = provider == "codex" ? "Choose this account’s CODEX_HOME folder. Credentials stay in that folder." : "Choose this account’s CLAUDE_CONFIG_DIR folder. Credentials stay in its own profile."
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            let account = Account(name: url.lastPathComponent, provider: provider, home: url.path)
            if !self.value.accounts.contains(where: { $0.home == account.home && $0.provider == provider }) { self.value.accounts.append(account); self.save() }
        }
    }
    func signIn(provider: String) {
        guard !signingIn else { return }
        let id = UUID().uuidString
        let directory = Self.directory.appendingPathComponent("Accounts/\(provider)/\(id)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let original = URL(fileURLWithPath: NSHomeDirectory() + (provider == "claude" ? "/.claude" : "/.codex"))
            for name in provider == "claude" ? ["settings.json", "CLAUDE.md", "skills", "agents", "commands", "plugins"] : ["config.toml", "AGENTS.md", "skills", "plugins"] {
                let source = original.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(name), withDestinationURL: source) }
            }
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = provider == "claude" ? ["claude", "auth", "login", "--claudeai"] : ["codex", "login", "--device-auth"]
            process.environment = agentEnvironment(Account(id: id, name: "", provider: provider, home: directory.path))
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
            signingIn = true; loginMessage = "Complete sign-in in your browser."
            process.terminationHandler = { process in
                DispatchQueue.main.async {
                    self.signingIn = false; self.login = nil
                    if process.terminationStatus == 0 {
                        self.value.accounts.append(Account(id: id, name: "\(provider.capitalized) account \(self.value.accounts.filter { $0.provider == provider }.count + 1)", provider: provider, home: directory.path))
                        self.save(); self.loginMessage = "Account added. Enable the accounts to use for fallback."
                    } else { self.loginMessage = "Sign-in did not complete. You can retry or use an existing profile." }
                }
            }
            try process.run(); login = process
            DispatchQueue.global().async {
                var buffer = Data()
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    if buffer.count > 16384 { buffer = Data(buffer.suffix(16384)) }
                    let text = String(decoding: buffer, as: UTF8.self).replacingOccurrences(of: #"\x1b\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
                    DispatchQueue.main.async { self.loginMessage = text }
                }
            }
        } catch { signingIn = false; self.error = error.localizedDescription }
    }
    func cancelSignIn() { login?.terminate() }
}

func agentEnvironment(_ account: Account? = nil) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
    environment["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    // Subscription selection must not silently use an inherited, metered API key.
    for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"] { environment.removeValue(forKey: key) }
    if let home = account?.home { environment[account?.provider == "claude" ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"] = home }
    return environment
}

struct SettingsView: View {
    @ObservedObject var session: Session
    @ObservedObject private var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Settings").font(.system(size: 24, weight: .semibold)); Spacer(); RoundButton(icon: "xmark", label: "Close settings") { settings.save(); dismiss() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Provider").font(.headline)
                        Picker("Routing", selection: $settings.value.provider) {
                            Text("Automatic").tag("auto"); Text("Claude").tag("claude"); Text("ChatGPT / Codex").tag("codex"); Text("Qwen").tag("qwen")
                        }.pickerStyle(.segmented).labelsHidden()
                        Text("Automatic tries enabled Claude accounts, then Codex accounts, then Qwen. Only an explicit usage limit triggers fallback. Changes apply after the current response.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Subscription accounts").font(.headline)
                        ForEach($settings.value.accounts) { $account in
                            HStack {
                                Toggle("", isOn: $account.enabled).labelsHidden().toggleStyle(.checkbox)
                                VStack(alignment: .leading, spacing: 2) {
                                    TextField("Account name", text: $account.name).textFieldStyle(.plain)
                                    Text(account.home == nil ? "\(account.provider.capitalized) · existing sign-in" : "\(account.provider.capitalized) · isolated profile").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Use") {
                                    settings.value.provider = account.provider
                                    for n in settings.value.accounts.indices where settings.value.accounts[n].provider == account.provider { settings.value.accounts[n].enabled = settings.value.accounts[n].id == account.id }
                                    settings.save()
                                }.font(.system(size: 11))
                            }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        }
                        HStack {
                            Menu("Add Claude account") { Button("Sign in with subscription") { settings.signIn(provider: "claude") }; Button("Use existing profile…") { settings.addProfile(provider: "claude") } }
                            Menu("Add Codex account") { Button("Sign in with subscription") { settings.signIn(provider: "codex") }; Button("Use existing profile…") { settings.addProfile(provider: "codex") } }
                        }.disabled(settings.signingIn)
                        if !settings.loginMessage.isEmpty {
                            Text(settings.loginMessage).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            if settings.signingIn { Button("Cancel sign-in") { settings.cancelSignIn() } }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Qwen on your own machine").font(.headline)
                        TextField("Ollama chat URL", text: $settings.value.qwenURL)
                        TextField("SOCKS proxy (optional)", text: $settings.value.qwenProxy)
                        TextField("Text model", text: $settings.value.qwenModel)
                        TextField("Vision model", text: $settings.value.qwenVisionModel)
                        Text("Uses the same Ollama connection as Jarvis. Qwen supports chat, images, and shell tools. Each shell command asks for approval. No model runs on this Mac unless you point this at localhost.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prompts stay about the work").font(.headline)
                        Text("vcx renders messages, code, images, questions, and actions consistently across providers. It adds no output-formatting prompt. Claude and Codex keep their own working instructions, skills, hooks, and permissions.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !settings.error.isEmpty { Text(settings.error).foregroundStyle(.orange).font(.system(size: 12)) }
                }.padding(.trailing, 8)
            }
            HStack { Text("Settings are shared across windows.").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button("Done") { settings.save(); dismiss() }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.defaultAction) }
        }.padding(28).background(Color(white: 0.06)).foregroundStyle(.white.opacity(0.92)).preferredColorScheme(.dark).onAppear { settings.reload() }.onDisappear { settings.save() }
    }
}

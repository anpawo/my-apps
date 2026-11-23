import SwiftUI

// Opened from the model, token and usage chips: the 5-hour and weekly quota of every agent on this Mac, read from each provider.
struct QuotaOverview: View {
    struct Line: Identifiable { var id: String { agent }; let agent: String, fiveHour: String, week: String }
    let changeModel: () -> Void
    @State private var lines: [Line]
    private let live: Bool
    // Claude's usage endpoint answers HTTP 429 when polled, so a reopened panel within a minute shows the last read.
    private static var cache: (at: Date, lines: [Line])?
    static let cacheLife: TimeInterval = 60
    // MAX_PROMPTS_PER_DAY in ~/.claude/skills/deep/ask-web.mjs.
    static let webDailyCap = 25

    init(lines: [Line]? = nil, changeModel: @escaping () -> Void) {
        self.changeModel = changeModel; live = lines == nil
        _lines = State(initialValue: lines ?? Self.cache?.lines ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quota on this Mac").font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { ForEach(["Agent", "5 hours", "Week"], id: \.self) { Text($0).foregroundStyle(.secondary) } }
                Divider()
                if lines.isEmpty { GridRow { Text("Loading…").foregroundStyle(.secondary) } }
                ForEach(lines) { line in
                    GridRow { ForEach([line.agent, line.fiveHour, line.week], id: \.self) { Text($0).lineLimit(1).fixedSize() } }
                }
            }.font(.system(size: 11, design: .monospaced))
            Button("Change this window's model…", action: changeModel).buttonStyle(.link).font(.system(size: 11))
        }.padding(14).fixedSize()
            .task {
                guard live else { return }
                if let cache = Self.cache, Date().timeIntervalSince(cache.at) < Self.cacheLife { return }
                lines = await Self.read()
                Self.cache = (Date(), lines)
            }
    }

    static func read() async -> [Line] {
        let accounts = Settings.shared.candidates("auto")
        async let agy = antigravity()
        var lines: [Line] = []
        for account in accounts where account.provider == "claude" {
            let name = accountName("Claude", account)
            do {
                let rate = try claudeRateLimits(try await readClaudeUsage(account))
                lines.append(line(name, rate))
            } catch { lines.append(Line(agent: name, fiveHour: error.localizedDescription.replacingOccurrences(of: "Usage unavailable: ", with: ""), week: "")) }
        }
        for account in accounts where account.provider == "codex" {
            let name = accountName("Codex", account)
            let rate = await Task.detached { codexRateLimits(home: account.home ?? NSHomeDirectory() + "/.codex") }.value
            lines.append(rate.map { line(name, $0) } ?? Line(agent: name, fiveHour: "No Codex turn yet", week: ""))
        }
        return lines + (await agy) + ["gemini", "grok", "muse", "meta"].map { web($0, webCount($0)) }
    }

    // Local caps count the deep skill's own prompts, separately from the websites' quotas.
    nonisolated static func webCount(_ site: String, day: Date = Date()) -> Int {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let path = NSHomeDirectory() + "/.local/state/" + site + "-web/" + formatter.string(from: day)
        return Int(((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static func web(_ site: String, _ count: Int) -> Line {
        Line(agent: (site == "meta" ? "Meta AI" : site.capitalized) + " web", fiveHour: "–", week: "\(count)/\(webDailyCap) today - reset 00h00")
    }

    static func accountName(_ agent: String, _ account: Account) -> String { account.name.isEmpty || account.name.hasPrefix("Default ") ? agent : agent + " · " + account.name }

    // primary/secondary windows as Session.updateUsage reads them: usedPercent, windowDurationMins, resetsAt.
    static func line(_ agent: String, _ rate: JSON) -> Line {
        let windows = ["primary", "secondary"].compactMap { rate[$0] as? JSON }
        func text(_ minutes: Int) -> String {
            guard let window = windows.first(where: { ($0["windowDurationMins"] as? NSNumber)?.intValue == minutes }), let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { return "–" }
            return quota(used: used, reset: (window["resetsAt"] as? NSNumber)?.doubleValue, weekly: minutes == 10080)
        }
        return Line(agent: agent, fiveHour: text(300), week: text(10080))
    }

    static func quota(used: Double, reset: Double?, weekly: Bool) -> String {
        let now = Date().timeIntervalSince1970
        guard let reset else { return "\(Int(used.rounded()))%" }
        // A window whose reset has passed starts again from zero.
        guard reset > now else { return "0%" }
        let countdown: String
        if weekly {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Europe/Paris"); formatter.dateFormat = "EEE HH'h'mm"
            countdown = formatter.string(from: Date(timeIntervalSince1970: reset))
        } else {
            let minutes = Int((reset - now) / 60)
            countdown = [(minutes / 60, "h"), (minutes % 60, "m")].filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined()
        }
        return "\(Int(used.rounded()))% - reset " + (countdown.isEmpty ? "0m" : countdown)
    }

    // Codex writes its plan windows into each turn's token_count event; the newest rollout holds the latest.
    nonisolated static func codexRateLimits(home: String) -> JSON? {
        let manager = FileManager.default
        var folder = home + "/sessions"
        for _ in 0..<3 {
            guard let newest = ((try? manager.contentsOfDirectory(atPath: folder)) ?? []).filter({ !$0.hasPrefix(".") }).max() else { return nil }
            folder += "/" + newest
        }
        let files = ((try? manager.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".jsonl") }
        let paths = files.map { folder + "/" + $0 }.sorted {
            ((try? manager.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) > ((try? manager.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast)
        }
        for path in paths {
            guard let data = manager.contents(atPath: path) else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON,
                      let limits = (event["payload"] as? JSON)?["rate_limits"] as? JSON else { continue }
                var rate: JSON = [:]
                for key in ["primary", "secondary"] {
                    guard let window = limits[key] as? JSON, let used = window["used_percent"] as? Double else { continue }
                    rate[key] = ["usedPercent": used, "windowDurationMins": window["window_minutes"] as? Int ?? 0, "resetsAt": window["resets_at"] as? Double as Any]
                }
                if !rate.isEmpty { return rate }
            }
        }
        return nil
    }

    // `agy -p /quota` prints one tab-separated line per model group: name, window, percent remaining, reset (ISO 8601).
    static func antigravity() async -> [Line] {
        let output = await Task.detached { () -> String in
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["agy", "-p", "/quota"]
            process.environment = agentEnvironment(); process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return "" }
            let timeout = DispatchWorkItem { if process.isRunning { endProcess(process, signal: SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            return String(decoding: data, as: UTF8.self)
        }.value
        let lines = antigravityQuota(output)
        return lines.isEmpty ? [Line(agent: "Antigravity", fiveHour: "Not reported", week: "")] : lines
    }

    static func antigravityQuota(_ output: String) -> [Line] {
        output.split(separator: "\n").compactMap { row -> Line? in
            let fields = row.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 4, let remaining = Double(fields[2].replacingOccurrences(of: "%", with: "")) else { return nil }
            let reset = ISO8601DateFormatter().date(from: fields[3])?.timeIntervalSince1970
            let text = quota(used: 100 - remaining, reset: reset, weekly: true)
            let weekly = fields[1].lowercased().contains("week")
            return Line(agent: "Antigravity · " + fields[0].replacingOccurrences(of: " models", with: "").replacingOccurrences(of: " Models", with: ""),
                        fiveHour: weekly ? "–" : text, week: weekly ? text : "–")
        }
    }
}

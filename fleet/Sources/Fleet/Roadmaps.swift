import Foundation

struct RoadmapStep: Identifiable, Equatable {
    var id: String
    var title: String
    var detail = ""
    var status = "Status unverified"
    var source: URL
}

struct RoadmapProject: Identifiable {
    var name: String
    var root: URL
    var sources: [URL]
    var kind: Kind
    var id: String { root.path }
    enum Kind { case roadmap, progress, publication }

    static func projects(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [Self] {
        let base = home.appendingPathComponent("self")
        func project(_ name: String, _ path: String, _ files: [String], _ kind: Kind) -> Self {
            let root = base.appendingPathComponent(path)
            return Self(name: name, root: root, sources: files.map { root.appendingPathComponent($0) }, kind: kind)
        }
        return [
            project("Recon", "s14/recon-v3-mr", ["PROGRESS.md"], .progress),
            project("Stele", "s14/stele", ["docs/roadmap/stele-roadmap-paper.md"], .roadmap),
            project("CER", "m3-labs/clients/cer", ["roadmap/drive-planner-roadmap.md"], .roadmap),
            project("Socials", "socials", ["thebestminute/PLAN.md", "pastmidnight/PLAN.md", "hypecheck/posting/PLAN.md"], .publication),
        ]
    }

    func working(_ sessions: [Session]) -> [Session] {
        sessions.filter { session in
            guard session.state == .running || session.state == .delegated else { return false }
            if let assignment = session.projectAssignment {
                guard let path = assignment.path else { return false }
                if path == root.path || path.hasPrefix(root.path + "/") { return true }
                guard root.path.hasPrefix(path + "/") else { return false }
                // Non-repository projects can belong to a parent card, with concrete work below it.
                return session.cwd == root.path || session.cwd.hasPrefix(root.path + "/") ||
                    (session.transcript?.projectEvidence.actions.contains {
                        $0.path == root.path || $0.path.hasPrefix(root.path + "/")
                    } ?? false)
            }
            return session.cwd == root.path || session.cwd.hasPrefix(root.path + "/")
        }
    }
}

struct RoadmapSnapshot {
    var project: RoadmapProject
    var steps: [RoadmapStep] = []
    var updated: Date?
    var notices: [String] = []
    var loaded = false
    static let staleAfter: TimeInterval = 14 * 24 * 60 * 60
    var stale: Bool { updated.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? false }

    static func read(_ project: RoadmapProject) -> Self {
        var result = Self(project: project, loaded: true)
        let maximumSourceBytes = 2 * 1024 * 1024
        var dates: [Date] = []
        for url in project.sources {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, size <= maximumSourceBytes,
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                result.notices.append("Source unavailable: " + url.lastPathComponent)
                continue
            }
            if let date = values.contentModificationDate { dates.append(date) }
            let parsed = RoadmapParser.steps(text, source: url, kind: project.kind)
            result.steps += parsed
            if parsed.isEmpty { result.notices.append("No supported steps in " + url.lastPathComponent) }
        }
        result.updated = dates.min()
        if project.kind == .progress { result.notices.insert("Progress log; ordered roadmap not found", at: 0) }
        if project.kind == .publication { result.notices.insert("Publication plans; no project-wide roadmap", at: 0) }
        return result
    }
}

enum RoadmapParser {
    static func steps(_ text: String, source: URL, kind: RoadmapProject.Kind) -> [RoadmapStep] {
        switch kind {
        case .roadmap: return roadmap(text, source: source)
        case .progress: return progress(text, source: source)
        case .publication: return publication(text, source: source)
        }
    }

    private static func roadmap(_ text: String, source: URL) -> [RoadmapStep] {
        let lines = text.components(separatedBy: .newlines)
        var columns: [String] = []
        var result: [RoadmapStep] = []
        var reading = false
        for line in lines {
            let cells = cells(line)
            if !reading, cells.first?.lowercased() == "step" {
                columns = cells; reading = true; continue
            }
            guard reading else { continue }
            if cells.isEmpty { if !result.isEmpty { break }; continue }
            guard cells.count > 1, cells[0].range(of: #"^[A-Z][0-9]+$"#, options: .regularExpression) != nil else { continue }
            let code = cells[0]
            let statusIndex = columns.firstIndex { $0.lowercased() == "status" }
            let status = statusIndex.flatMap { cells.indices.contains($0) ? cells[$0] : nil } ?? "Status unverified"
            let partialPattern = #"\bpartial\s+"# + NSRegularExpression.escapedPattern(for: code) + #"\b"#
            let partial = text.range(of: partialPattern, options: [.regularExpression, .caseInsensitive]) != nil
            result.append(RoadmapStep(id: code, title: cells[1], detail: section(code, lines: lines),
                                      status: partial ? "Partial; acceptance unverified" : status, source: source))
        }
        return result
    }

    private static func section(_ code: String, lines: [String]) -> String {
        let pattern = #"^#{3,4}\s+"# + NSRegularExpression.escapedPattern(for: code) + #"\b"#
        guard let start = lines.firstIndex(where: { $0.range(of: pattern, options: .regularExpression) != nil }) else { return "" }
        let following = lines.dropFirst(start + 1).prefix { !$0.hasPrefix("###") }
        let purpose = following.first { $0.hasPrefix("**Goal") || $0.hasPrefix("**Purpose") }
        return purpose.map(clean) ?? ""
    }

    private static func progress(_ text: String, source: URL) -> [RoadmapStep] {
        // A log is not a sequence of phases: retain its own order and explicit status labels.
        text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            guard line.hasPrefix("- "), let split = line.firstIndex(of: ":") else { return nil }
            let prefix = String(line[..<split]).lowercased()
            let status: String
            if prefix.hasPrefix("- done") || prefix.hasPrefix("- fait") { status = "Done (source)" }
            else if prefix.hasPrefix("- next") || prefix.hasPrefix("- suite") || prefix.hasPrefix("- à faire") { status = "Next (source)" }
            else if prefix.hasPrefix("- bloqué") || prefix.hasPrefix("- blocked") { status = "Blocked (source)" }
            else { return nil }
            let body = clean(String(line[line.index(after: split)...]))
            guard !body.isEmpty else { return nil }
            return RoadmapStep(id: "log-\(index)", title: String(body.prefix(titleLimit)),
                               detail: body, status: status, source: source)
        }
    }

    private static let titleLimit = 160

    private static func publication(_ text: String, source: URL) -> [RoadmapStep] {
        var header: [String] = []
        var result: [RoadmapStep] = []
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let row = cells(line)
            if row.isEmpty { header = []; continue }
            if row.contains(where: { ["task", "output", "status", "state", "video"].contains($0.lowercased()) }) {
                header = row; continue
            }
            guard !header.isEmpty, row.count == header.count,
                  !row.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) else { continue }
            let titleIndex = header.firstIndex { value in
                ["task", "clip", "episode", "subject", "topic", "content"].contains(value.lowercased()) || value.lowercased().hasPrefix("source (")
            } ?? min(2, row.count - 1)
            let statusIndex = header.firstIndex { ["state", "status"].contains($0.lowercased()) }
            let title = row[titleIndex]
            guard !title.isEmpty else { continue }
            result.append(RoadmapStep(id: source.path + "#\(index)", title: String(title.prefix(titleLimit)),
                                      detail: row.joined(separator: " · "),
                                      status: statusIndex.map { row[$0] } ?? "Plan; status unverified", source: source))
        }
        return result
    }

    private static func cells(_ line: String) -> [String] {
        guard line.trimmingCharacters(in: .whitespaces).hasPrefix("|") else { return [] }
        return line.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst().dropLast().map { clean(String($0)) }
    }

    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RoadmapActivity {
    static func steps(for session: Session, in steps: [RoadmapStep]) -> Set<String> {
        let label = session.context ?? ""
        let evidence = session.transcript?.projectEvidence.prompt ?? ""
        let prompt = evidence.isEmpty ? session.transcript?.lastPrompt ?? "" : evidence
        // Only the current task's opening line is evidence, not roadmap quotations later in a brief.
        let opening = String(prompt.components(separatedBy: .newlines).first?.prefix(openingLimit) ?? "")
        let tasks = [label, opening] + session.subagents.map(\.task)
        return Set(steps.filter { step in
            tasks.contains { task in
                let normalized = task.lowercased()
                guard !normalized.contains("not "), !normalized.contains("later"), !normalized.contains("roadmap"),
                      !normalized.contains("plan all"), !normalized.contains("compare"),
                      !normalized.contains("completed"), !normalized.contains("done") else { return false }
                let action = normalized.range(of: #"\b(fix|build|implement|work|review|test|validate|repair|finish|integrate|audit)\b"#,
                                              options: .regularExpression) != nil
                guard action || task.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == step.id else { return false }
                let code = step.id.range(of: #"^[A-Z][0-9]+$"#, options: .regularExpression) != nil
                if code {
                    return task.range(of: #"\b"# + step.id + #"\b"#, options: [.regularExpression, .caseInsensitive]) != nil
                }
                return step.title.count >= minimumTitleLength && normalized.contains(step.title.lowercased())
            }
        }.map(\.id))
    }

    private static let openingLimit = 200
    private static let minimumTitleLength = 12
}

@MainActor
final class RoadmapStore: ObservableObject {
    @Published var snapshots = RoadmapProject.projects().map { RoadmapSnapshot(project: $0) }
    static let refreshInterval: TimeInterval = 15
    private static let previewTimeout: TimeInterval = 8
    private static let previewPoll: TimeInterval = 0.05
    private var refreshedAt = Date.distantPast
    private var refreshing = false
    var loaded: Bool { snapshots.allSatisfy(\.loaded) }

    func refresh() async {
        guard !refreshing, !loaded || Date().timeIntervalSince(refreshedAt) >= Self.refreshInterval else { return }
        refreshing = true
        let projects = snapshots.map(\.project)
        snapshots = await Task.detached(priority: .utility) { projects.map(RoadmapSnapshot.read) }.value
        refreshedAt = Date()
        refreshing = false
    }

    func loadForPreview() -> Bool {
        Task { await refresh() }
        let deadline = Date().addingTimeInterval(Self.previewTimeout)
        while !loaded, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(Self.previewPoll))
        }
        return loaded
    }
}

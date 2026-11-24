import CryptoKit
import Foundation

struct ProjectAssignment: Codable, Equatable {
    var path: String?
    var source: String
    var revision: Int
    var catalogueRevision: Int
    var cwd: String
    var fingerprint: String
}

@MainActor
final class ProjectGrouping {
    private static let maximumAssignments = 1024
    private var catalogue: ProjectCatalogue
    private var refreshing = false
    private let file: URL
    private var assignments: [String: ProjectAssignment]
    private var canSave = true

    init(root: String = Config.projectRoot,
         file: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/fleet/project-assignments.json")) {
        catalogue = ProjectCatalogue(root: root)
        self.file = file
        assignments = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            do { assignments = try JSONDecoder().decode([String: ProjectAssignment].self, from: Data(contentsOf: file)) }
            catch { canSave = false; NSLog("Fleet: project assignments could not be read: %@", error.localizedDescription) }
        }
    }

    func apply(to sessions: [Session]) -> [Session] {
        refreshCatalogue()
        var changed = false
        let result = sessions.map { original -> Session in
            var session = original
            let key = identity(session)
            var evidence = session.transcript?.projectEvidence ?? ProjectEvidence()
            if evidence.prompt.isEmpty, let prompt = session.transcript?.lastPrompt { evidence.userPrompt(prompt) }
            let fingerprint = Self.fingerprint(evidence, cwd: session.cwd, catalogue: catalogue.version)
            let previous = assignments[key]
            if let previous, previous.fingerprint == fingerprint, valid(previous.path) {
                session.projectAssignment = previous
                return session
            }
            let next = resolve(evidence, cwd: session.cwd, previous: previous, fingerprint: fingerprint)
            session.projectAssignment = next
            assignments[key] = next
            changed = true
            return session
        }
        if changed { save(live: Set(sessions.map(identity))) }
        return result
    }

    private func refreshCatalogue() {
        if catalogue.revision == 0 { catalogue.refresh(); return }
        guard catalogue.needsRefresh, !refreshing else { return }
        refreshing = true
        let root = catalogue.root
        Task {
            let updated = await Task.detached {
                let catalogue = ProjectCatalogue(root: root)
                catalogue.refresh()
                return catalogue
            }.value
            catalogue = updated
            refreshing = false
        }
    }

    private func resolve(_ evidence: ProjectEvidence, cwd: String, previous: ProjectAssignment?,
                         fingerprint: String) -> ProjectAssignment {
        let actions = Set(evidence.actions.compactMap { catalogue.project(at: $0.path)?.path })
        var task = evidence.prompt
        if previous?.source != "directory correction", catalogue.named(in: task).isEmpty, catalogue.mentionedPaths(in: task).isEmpty {
            task = evidence.prompts.reversed().first { text in
                let hits = catalogue.named(in: text)
                return hits.count == 1 && (actions.isEmpty || actions.contains(hits[0].path))
            } ?? task
        }
        let paths = catalogue.mentionedPaths(in: task)
        let named = paths.isEmpty ? catalogue.named(in: task) : paths
        let current = catalogue.project(at: cwd)?.path
        var path: String?
        var source = "unresolved"
        if previous?.source == "override", let pinned = previous?.path, valid(pinned) {
            path = pinned; source = "override"
        } else if let previous, previous.cwd != cwd, let current {
            path = current; source = "directory correction"
        } else if named.count == 1 {
            // BM25 orders candidates; an exact, unique project name supplies the acceptance evidence.
            path = catalogue.ranked(for: task).first { $0.path == named[0].path }?.path ?? named[0].path
            source = paths.isEmpty ? "name" : "task path"
        } else if named.count > 1 {
            let supported = named.filter { actions.contains($0.path) }
            if supported.count == 1 { path = supported[0].path; source = "corroborated edit" }
        } else if previous?.source == "directory correction", let accepted = previous?.path, valid(accepted) {
            path = accepted; source = "directory correction"
        } else if let directory = evidence.actions.last(where: { $0.kind == "directory" }),
                  let project = catalogue.project(at: directory.path) {
            path = project.path; source = "completed cd"
        } else if actions.count == 1, let target = actions.first,
                  previous?.path == nil || previous?.path == target || previous?.source == "directory" {
            path = target; source = "completed edit"
        } else if let previous, let accepted = previous.path, valid(accepted) {
            path = accepted; source = previous.source
        } else if let current {
            path = current; source = "directory"
        }
        return ProjectAssignment(path: path, source: source, revision: (previous?.revision ?? 0) + 1,
                                 catalogueRevision: catalogue.revision, cwd: cwd, fingerprint: fingerprint)
    }

    private func identity(_ session: Session) -> String {
        session.transcript?.projectIdentity ?? session.sid.map { "transcript:" + $0 } ??
            "process:\(session.proc.pid):\(session.proc.startedAt.timeIntervalSince1970)"
    }

    private func valid(_ path: String?) -> Bool {
        guard let path else { return true }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private static func fingerprint(_ evidence: ProjectEvidence, cwd: String, catalogue: String) -> String {
        let content = [cwd, catalogue, evidence.prompt] + evidence.prompts + evidence.actions.map { $0.kind + ":" + $0.path }
        return SHA256.hash(data: Data(content.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func save(live: Set<String>) {
        guard canSave else { return }
        if assignments.count > Self.maximumAssignments {
            let kept = assignments.keys.sorted().filter { !live.contains($0) }
                .prefix(assignments.count - max(Self.maximumAssignments, live.count))
            for key in kept { assignments[key] = nil }
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(assignments).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("Fleet: project assignments could not be saved: %@", error.localizedDescription) }
    }
}

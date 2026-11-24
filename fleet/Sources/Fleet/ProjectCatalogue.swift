import Foundation
import SQLite3
import CryptoKit

final class ProjectCatalogue {
    struct Project: Equatable {
        var path: String
        var name: String { (path as NSString).lastPathComponent }
    }

    private static let discoveryDepth = 5
    private static let refreshInterval: TimeInterval = 60
    private static let descriptionCharacters = 2000
    private static let minimumNameLength = 3
    private static let nameWeight = 5
    private static let maximumQueryTerms = 128
    private static let skipped: Set<String> = [
        "node_modules", "vendor", "dist", "build", "target", "venv", "__pycache__", "Pods", "Carthage",
        "vcpkg_installed", "worktrees", "data", "cache", "logs",
    ]
    let root: String
    private(set) var projects: [Project] = []
    private(set) var revision = 0
    private(set) var version = ""
    private var checked = Date.distantPast
    private var database: OpaquePointer?
    private var signature = ""
    var needsRefresh: Bool { Date().timeIntervalSince(checked) >= Self.refreshInterval }

    init(root: String = Config.projectRoot) {
        self.root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        sqlite3_open(":memory:", &database)
        sqlite3_exec(database, "CREATE VIRTUAL TABLE projects USING fts5(path UNINDEXED, name, description)", nil, nil, nil)
    }

    deinit { sqlite3_close(database) }

    func refresh(now: Date = Date(), force: Bool = false) {
        guard force || now.timeIntervalSince(checked) >= Self.refreshInterval else { return }
        checked = now
        var paths = Set<String>()
        discover(root, depth: 0, paths: &paths)
        let rows = paths.sorted().map { path -> (Project, String) in
            let text = (try? String(contentsOfFile: path + "/README.md", encoding: .utf8)) ?? ""
            return (Project(path: path), String(text.prefix(Self.descriptionCharacters)))
        }
        let next = rows.map { $0.0.path + "\n" + $0.1 }.joined(separator: "\0")
        guard signature != next || revision == 0 else { return }
        signature = next
        version = SHA256.hash(data: Data(next.utf8)).map { String(format: "%02x", $0) }.joined()
        projects = rows.map(\.0)
        revision += 1
        sqlite3_exec(database, "DELETE FROM projects", nil, nil, nil)
        for (project, description) in rows { index(project, description: description) }
    }

    private func discover(_ path: String, depth: Int, paths: inout Set<String>) {
        let files = FileManager.default
        let isRepo = files.fileExists(atPath: path + "/.git")
        if depth == 1 || isRepo { paths.insert(path) }
        if let text = try? String(contentsOfFile: path + "/.fleet", encoding: .utf8) {
            let names = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            paths.insert(path)
            for name in names where !name.isEmpty {
                let child = URL(fileURLWithPath: path + "/" + name).standardized.path
                if child.hasPrefix(path + "/"), directory(child) { paths.insert(child) }
            }
        }
        guard depth < Self.discoveryDepth else { return }
        let children = (try? files.contentsOfDirectory(atPath: path)) ?? []
        for child in children.sorted() where !child.hasPrefix(".") && !Self.skipped.contains(child) {
            let next = path + "/" + child
            let url = URL(fileURLWithPath: next)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            discover(next, depth: depth + 1, paths: &paths)
        }
    }

    func project(at path: String) -> Project? {
        let canonical = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        guard canonical.hasPrefix(root + "/") else { return nil }
        var current = canonical
        var nearest: Project?
        while current != root {
            if let text = try? String(contentsOfFile: current + "/.fleet", encoding: .utf8) {
                let names = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                if names.isEmpty { return Project(path: current) }
                let boundaries = names.map { URL(fileURLWithPath: current + "/" + $0).standardized.path }
                    .filter { $0.hasPrefix(current + "/") && (canonical == $0 || canonical.hasPrefix($0 + "/")) }
                    .sorted { $0.count > $1.count }
                if let boundary = boundaries.first { return Project(path: boundary) }
            }
            if nearest == nil {
                nearest = projects.first { $0.path == current }
                if nearest == nil, FileManager.default.fileExists(atPath: current + "/.git") { nearest = Project(path: current) }
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nearest.map(worktree)
    }

    private func worktree(_ project: Project) -> Project {
        guard let pointer = try? String(contentsOfFile: project.path + "/.git", encoding: .utf8),
              pointer.hasPrefix("gitdir: "), let cut = pointer.range(of: "/.git/worktrees/") else { return project }
        let repo = String(pointer.dropFirst("gitdir: ".count).prefix(upTo: cut.lowerBound))
        let path = URL(fileURLWithPath: repo, relativeTo: URL(fileURLWithPath: project.path + "/")).standardized.path
        return path.hasPrefix(root + "/") ? Project(path: path) : project
    }

    func named(in text: String) -> [Project] {
        let normalized = " " + Self.words(text).joined(separator: " ") + " "
        let hits = projects.filter { project in
            let name = Self.words(project.name).joined(separator: " ")
            return name.count >= Self.minimumNameLength && normalized.contains(" " + name + " ")
        }
        // Naming a child also names its parent in a path; retain the specific target.
        return hits.filter { parent in !hits.contains { $0.path.hasPrefix(parent.path + "/") } }
    }

    func mentionedPaths(in text: String) -> [Project] {
        let expanded = text.replacingOccurrences(of: "~/self/", with: root + "/")
        let hits = projects.filter { project in
            expanded.ranges(of: project.path).contains { range in
                let before = range.lowerBound == expanded.startIndex ? nil : expanded[expanded.index(before: range.lowerBound)]
                let after = range.upperBound == expanded.endIndex ? nil : expanded[range.upperBound]
                return (before == nil || " \n\t\"'`(<".contains(before!)) &&
                    (after == nil || "/ \n\t\"'`)>,.:".contains(after!))
            }
        }
        return hits.filter { parent in !hits.contains { $0.path.hasPrefix(parent.path + "/") } }
    }

    func ranked(for text: String) -> [Project] {
        let terms = Array(Set(Self.words(text))).sorted().prefix(Self.maximumQueryTerms)
        guard !terms.isEmpty else { return [] }
        let query = terms.map { "\"" + $0 + "\"" }.joined(separator: " OR ")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT path FROM projects WHERE projects MATCH ? ORDER BY bm25(projects, 0, \(Self.nameWeight), 1), path", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(query, to: statement, at: 1)
        var matches: [Project] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { matches.append(Project(path: String(cString: value))) }
        }
        return matches
    }

    private func index(_ project: Project, description: String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO projects VALUES (?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(project.path, to: statement, at: 1)
        bind(Self.words(project.name).joined(separator: " "), to: statement, at: 2)
        bind(description, to: statement, at: 3)
        sqlite3_step(statement)
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at column: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, column, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }

    private func directory(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

import Foundation

@MainActor
enum ProjectGroupingCheck {
    static func run(_ expect: (Bool, Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-grouping-\(getpid())")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("self")
        for name in ["atlas/.git", "beacon/.git", "mono/.git", "mono/board", "mono/sub/.git", "archive"] {
            try! FileManager.default.createDirectory(at: projects.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try! "board\n".write(to: projects.appendingPathComponent("mono/.fleet"), atomically: true, encoding: .utf8)
        try! "Position cards and reconciliation".write(to: projects.appendingPathComponent("atlas/README.md"), atomically: true, encoding: .utf8)
        catalogue(projects.path, expect)
        resolution(projects.path, state: root.appendingPathComponent("state.json"), expect)
        completedActions(projects.path, expect)
        codexActions(projects.path, expect)
        directoryCorrections(projects.path, expect)
        explicitOverride(projects.path, expect)
        nativeEvidence(root, expect)
    }

    private static func catalogue(_ root: String, _ expect: (Bool, Bool, String) -> Void) {
        let catalogue = ProjectCatalogue(root: root)
        catalogue.refresh()
        let ranked = catalogue.ranked(for: "position reconciliation")
        expect(ranked.first?.path == root + "/atlas", true, "grouping: BM25 retrieves project descriptions")
        expect(catalogue.project(at: root + "/mono/board/file.swift")?.path == root + "/mono/board", true,
               "grouping: a registered fleet subfolder owns its files")
        expect(catalogue.project(at: root + "/mono/sub/src")?.path == root + "/mono/sub", true,
               "grouping: nested repositories keep their specific project")
        expect(catalogue.named(in: "fix BEACON").map(\.name) == ["beacon"], true,
               "grouping: exact project names ignore case")
        expect(catalogue.named(in: "beaconing").isEmpty, true, "grouping: project names require word boundaries")
        expect(catalogue.mentionedPaths(in: root + "/atlas-other/file").isEmpty, true,
               "grouping: project paths require component boundaries")
        let oldVersion = catalogue.version
        try! FileManager.default.createDirectory(atPath: root + "/new-project/.git", withIntermediateDirectories: true)
        catalogue.refresh(force: true)
        expect(catalogue.version != oldVersion && catalogue.named(in: "new project").count == 1, true,
               "grouping: catalogue refresh discovers new projects and invalidates its version")
    }

    private static func resolution(_ root: String, state: URL, _ expect: (Bool, Bool, String) -> Void) {
        let grouping = ProjectGrouping(root: root, file: state)
        var session = session(cwd: root + "/beacon", prompt: "Fix atlas positions")
        let assigned = grouping.apply(to: [session])[0]
        expect(assigned.projectAssignment?.path == root + "/atlas" && assigned.cwd == root + "/beacon", true,
               "grouping: task intent corrects a launch folder without changing execution cwd")
        expect(grouping.apply(to: [session])[0].projectAssignment?.revision == assigned.projectAssignment?.revision, true,
               "grouping: unchanged evidence does not reclassify a session")
        session.transcript?.projectEvidence.userPrompt("continue please")
        session.transcript?.lastPrompt = "continue please"
        expect(grouping.apply(to: [session])[0].projectAssignment?.path == root + "/atlas", true,
               "grouping: a vague follow-up preserves accepted task intent")
        let restored = ProjectGrouping(root: root, file: state).apply(to: [session])[0]
        expect(restored.projectAssignment?.path == root + "/atlas", true,
               "grouping: assignment survives a Fleet restart")
        session.transcript?.projectEvidence.userPrompt("compare atlas and beacon")
        expect(grouping.apply(to: [session])[0].projectAssignment?.path == nil, true,
               "grouping: a task spanning projects remains unresolved")
        var other = Self.session(cwd: "/", prompt: "what should I cook")
        other.runtimeSessionID = UUID().uuidString
        let pair = grouping.apply(to: [assigned, other])
        expect(pair[0].projectAssignment?.path != nil && pair[1].dirName == "Unassigned", true,
               "grouping: sessions sharing a native process retain independent assignments")
        var vague = Self.session(cwd: "/", prompt: "position reconciliation")
        vague.runtimeSessionID = "fresh-vague-task"
        expect(grouping.apply(to: [vague])[0].projectAssignment?.path == nil, true,
               "grouping: an uncalibrated BM25 score never forces a project")
        var unresolved = Self.session(cwd: Config.projectRoot + "/grouping-fixture", prompt: "compare projects")
        unresolved.projectAssignment = ProjectAssignment(path: nil, source: "unresolved", revision: 1,
                                                         catalogueRevision: 1, cwd: unresolved.cwd, fingerprint: "")
        expect(unresolved.groupKey == "Unassigned" && !unresolved.isSelf, true,
               "grouping: unresolved sessions never advertise a fictitious project to the prompt router")
    }

    private static func completedActions(_ root: String, _ expect: (Bool, Bool, String) -> Void) {
        var evidence = ProjectEvidence()
        evidence.userPrompt("fix it\nVCX note, not part of the request: beacon")
        evidence.ingest(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "edit", "name": "Edit",
                            "input": ["file_path": root + "/atlas/a.swift"]]]]])
        expect(evidence.actions.isEmpty, true, "grouping: pending edits do not count as completed work")
        evidence.ingest(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "edit", "is_error": true]]]])
        expect(evidence.actions.isEmpty, true, "grouping: failed edits do not select a project")
        evidence.nativeItem(["type": "commandExecution", "status": "completed", "exitCode": 0,
                             "command": "Read\n{\"file_path\":\"\(root)/beacon/dependency.swift\"}"])
        expect(evidence.actions.isEmpty && !evidence.prompt.contains("beacon"), true,
               "grouping: dependency reads and injected VCX notes do not redirect a task")
        evidence.nativeItem(["type": "fileChange", "status": "completed", "changes": [["path": root + "/atlas/a.swift"]]])
        var candidate = session(cwd: "/", prompt: "fix it")
        candidate.transcript?.projectEvidence = evidence
        let file = URL(fileURLWithPath: root + "/actions.json")
        let assigned = ProjectGrouping(root: root, file: file).apply(to: [candidate])[0]
        expect(assigned.projectAssignment?.path == root + "/atlas", true,
               "grouping: a completed native file change resolves a vague task")
        expect(ProjectEvidence.directoryChange("cd '\(root)/atlas'") == root + "/atlas", true,
               "grouping: a literal standalone cd supplies directory evidence")
        expect(ProjectEvidence.directoryChange("cd \(root)/atlas && read something") == nil &&
               ProjectEvidence.directoryChange("cd $(pwd)") == nil, true,
               "grouping: compound and dynamic shell commands are not interpreted as directory changes")
    }

    private static func nativeEvidence(_ root: URL, _ expect: (Bool, Bool, String) -> Void) {
        let file = root.appendingPathComponent("native/project/chat.json")
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot: [String: Any] = ["rows": [
            ["kind": "user", "items": [["content": [["text": "fix atlas"]]]]],
            ["kind": "activity", "items": [["type": "fileChange", "status": "completed", "changes": [["path": root.path + "/self/atlas/a.swift"]]]]],
            ["kind": "user", "items": [["content": [["text": "# AGENTS.md beacon"]]]]],
        ]]
        try! JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        let store = NativeProjectEvidence()
        let evidence = store.read(file.path, root: root.path)
        expect(evidence?.prompt == "fix atlas" && evidence?.actions.count == 1, true,
               "grouping: native snapshots preserve task intent and completed actions across providers")
        expect(store.read(root.appendingPathComponent("outside.json").path, root: root.path) == nil, true,
               "grouping: native evidence is restricted to the snapshot directory")
        expect(store.read(file.path, root: root.path, refreshing: false)?.prompt == "fix atlas", true,
               "grouping: streaming turns reuse native evidence without parsing snapshots again")
    }

    private static func codexActions(_ root: String, _ expect: (Bool, Bool, String) -> Void) {
        var evidence = ProjectEvidence()
        evidence.userPrompt("fix it")
        let patch = "*** Begin Patch\n*** Update File: \(root)/atlas/a.swift\n*** End Patch"
        evidence.ingest(["type": "response_item", "payload": ["type": "custom_tool_call", "name": "apply_patch", "call_id": "p", "input": patch]])
        evidence.ingest(["type": "response_item", "payload": ["type": "custom_tool_call_output", "call_id": "p", "output": "{\"metadata\":{\"exit_code\":0},\"output\":\"Success\"}"]])
        expect(evidence.actions.map(\.path) == [root + "/atlas/a.swift"], true,
               "grouping: a successful Codex patch supplies edited paths")
        let arguments = try! JSONSerialization.data(withJSONObject: ["cmd": "cd " + root + "/beacon"])
        evidence.ingest(["payload": ["type": "function_call", "name": "exec_command", "call_id": "c", "arguments": String(decoding: arguments, as: UTF8.self)]])
        evidence.ingest(["payload": ["type": "function_call_output", "call_id": "c", "output": "{\"exit_code\":1}"]])
        expect(evidence.actions.count == 1, true, "grouping: an unsuccessful Codex command supplies no directory evidence")
    }

    private static func directoryCorrections(_ root: String, _ expect: (Bool, Bool, String) -> Void) {
        let grouping = ProjectGrouping(root: root, file: URL(fileURLWithPath: root + "/correction.json"))
        var candidate = session(cwd: root + "/beacon", prompt: "fix atlas")
        _ = grouping.apply(to: [candidate])
        candidate.transcript?.cwd = root + "/beacon/src"
        try! FileManager.default.createDirectory(atPath: root + "/beacon/src", withIntermediateDirectories: true)
        let corrected = grouping.apply(to: [candidate])[0]
        candidate.transcript?.projectEvidence.userPrompt("continue")
        let followed = grouping.apply(to: [candidate])[0]
        expect(corrected.projectAssignment?.path == root + "/beacon" && followed.projectAssignment?.path == root + "/beacon", true,
               "grouping: an explicit directory correction survives a vague follow-up")
    }

    private static func session(cwd: String, prompt: String) -> Session {
        var evidence = ProjectEvidence()
        evidence.userPrompt(prompt)
        let transcript = TranscriptInfo(path: "/tmp/grouping-check.jsonl", projectEvidence: evidence,
                                        title: nil, lastPrompt: prompt, hasPendingTool: false, pendingToolNames: [],
                                        pendingToolLabels: [], pendingTaskIDs: [], cwd: cwd, turnOpen: false,
                                        lastActivity: Date(), preview: [])
        return Session(proc: ClaudeProcess(pid: 42, ppid: 1, cwd: cwd, tty: "", startedAt: Date(), cpuNanos: 0, vcx: true),
                       runtimeSessionID: "grouping-check", transcript: transcript, state: .ready, cpuPercent: 0)
    }

    private static func explicitOverride(_ root: String, _ expect: (Bool, Bool, String) -> Void) {
        let candidate = session(cwd: root + "/atlas", prompt: "fix atlas")
        let file = URL(fileURLWithPath: root + "/override.json")
        let pinned = ProjectAssignment(path: root + "/beacon", source: "override", revision: 1,
                                       catalogueRevision: 0, cwd: candidate.cwd, fingerprint: "")
        try! JSONEncoder().encode(["transcript:grouping-check": pinned]).write(to: file)
        let resolved = ProjectGrouping(root: root, file: file).apply(to: [candidate])[0]
        expect(resolved.projectAssignment?.path == root + "/beacon" && resolved.cwd == root + "/atlas", true,
               "grouping: a persisted explicit override outranks inference without moving commands")
    }
}

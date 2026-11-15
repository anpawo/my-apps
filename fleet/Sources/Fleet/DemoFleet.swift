import AppKit

/// Synthetic sessions, for looking at the panel at sizes you do not happen to have running.
///
/// The grid changes shape with the count — two columns, then three, then it pages sideways —
/// and those rules are otherwise only checkable by starting nine terminals. Used by
/// `--render --fake <n>`; nothing reaches this in normal operation.
enum DemoFleet {

    /// What `--fake` was given: a count, or a count per directory — `4,2,1` is a group of four,
    /// a group of two and a session alone, the groups being one more shape nobody has running.
    /// `3,4/2,1` puts the groups after the `/` on the next desktop: see `Spaces.desktops`.
    static func sessions(_ argument: String) -> [Session]? {
        let desks = argument.split(separator: "/").map { $0.split(separator: ",").compactMap { Int($0) } }
        let sizes = desks.flatMap { $0 }
        guard let count = sizes.first else { return nil }
        if sizes.count == 1 { return sessions(count) }
        let folders = sizes.enumerated().flatMap { Array(repeating: $0.offset, count: max(0, $0.element)) }
        let fleet = sessions(folders.count, folders: folders)
        if desks.count > 1 {
            let desk = desks.enumerated().flatMap { Array(repeating: $0.offset, count: $0.element.reduce(0) { $0 + max(0, $1) }) }
            desktops = Dictionary(uniqueKeysWithValues: zip(fleet.map(\.id), desk))
        }
        return fleet
    }

    /// Where `--fake` put each session, when it was given desktops.
    static var desktops: [String: Int]?

    static func sessions(_ count: Int, folders: [Int]? = nil) -> [Session] {
        let names = ["portfolio", "atlas", "video-code", "my-hub", "fleet", "siege",
                     "orchard", "lantern", "harbour", "quarry", "meridian", "tessera"]
        let states: [SessionState] = [.ready, .running, .delegated, .awaitingAnswer, .apiError, .paused, .fresh]

        return (0 ..< count).map { i in
            let state = states[i % states.count]
            let name = names[(folders?[i] ?? i) % names.count]
            let proc = ClaudeProcess(pid: pid_t(90000 + i), ppid: 1,
                                     cwd: "/Users/\(NSUserName())/self/\(name)",
                                     tty: "/dev/ttys0\(i)", startedAt: Date().addingTimeInterval(-3600), cpuNanos: 0)

            var info = TranscriptInfo(
                path: "/tmp/\(name).jsonl",
                title: "Work on \(name)",
                lastPrompt: nil,
                permissionMode: nil,
                hasPendingTool: state != .ready,
                pendingToolNames: state == .ready ? [] : ["Bash"],
                pendingToolLabels: state == .ready ? [] : ["Bash npm test"],
                pendingTaskIDs: [],
                lastCompletedTool: "Read",
                cwd: "/Users/\(NSUserName())/self/\(name)",
                turnOpen: state == .running,
                lastActivity: Date(),
                preview: [
                    PreviewLine(kind: .user, text: "Fix the thing in \(name)"),
                    PreviewLine(kind: .tool, text: "Read \(name).swift"),
                    PreviewLine(kind: .assistant, text: "Found it — one line, in the parser."),
                ])

            // Every third one has delegated, so the orange line is on screen too.
            // And the delegated one too: its two pills side by side are the widest header.
            if i % 3 == 1 || state == .delegated {
                info.pendingTaskIDs = ["task-\(i)"]
                info.pendingToolNames = ["Task"]
                info.subagents = [SubagentRun(id: "a\(i)", kind: "Explore",
                                              task: "Audit the palette",
                                              step: "Grep contrast-ratio",
                                              lastActivity: Date())]
            }
            // A working one with no agent out has a shell out too: the pill then names both.
            if state == .delegated || (state == .running && i % 3 != 1) {
                info.backgroundShellsStartedAt = [Date().addingTimeInterval(-22 * 60)]
            }

            return Session(proc: proc, transcript: state == .fresh ? nil : info, state: state,
                           cpuPercent: state == .running ? 4 : 0)
        }
    }

    /// The side columns filled with nothing of this machine's, as `sessions` does the grid.
    /// The mail, the todos, the school and the bank's export are their owner's: a picture
    /// meant to be published — the README's — is drawn with `--fake` for that reason.
    @MainActor
    static func fill(_ controller: AppController) {
        let now = Date()
        let iso = ISO8601DateFormatter()
        func text(_ value: String) -> [String: Any] { ["stringValue": value] }
        func stamp(_ days: Double) -> [String: Any] {
            ["timestampValue": iso.string(from: now.addingTimeInterval(days * 86_400))]
        }
        func document(_ name: String, _ fields: [String: [String: Any]]) -> Firestore.Document {
            let json = try! JSONSerialization.data(withJSONObject: ["name": name, "fields": fields])
            return try! JSONDecoder().decode(Firestore.Document.self, from: json)
        }

        let mail = [("Invoice for the March sprint", "Ada Quill", -0.2),
                    ("Your talk is accepted", "Lantern Conf", -1),
                    ("Renewal notice for orchard.dev", "Harbour Domains", -3)]
            .enumerated().compactMap { index, mail in
                Mail(document("mail/\(index)", ["gist": text(mail.0), "sender": text(mail.1),
                                                "receivedAt": stamp(mail.2)]))
            }
        let todos = [("Renew the domain", 2.0 as Double?), ("Reply to the sprint review", nil),
                     ("Book the train to Lyon", nil), ("Clean up the staging bucket", nil)]
            .enumerated().map { index, todo in
                var fields = ["name": text(todo.0), "state": text(Todo.Pile.todo),
                              "createdAt": stamp(-Double(index + 1))]
                if let due = todo.1 { fields["dueAt"] = stamp(due) }
                return Todo(document("todos/\(index)", fields))
            }

        let folder = FileManager.default.temporaryDirectory.appending(path: "fleet-demo")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let school: [String: Any] = [
            "generatedAt": iso.string(from: now), "sessionOk": true,
            "errors": [String](), "deadlines": [String](),
            "registrations": [("G-ALG-500", "G5 - Algorithms", 5), ("G-NET-500", "G5 - Networks", 3),
                              ("G-CMP-500", "G5 - Compilers", 7)].map {
                ["code": $0.0, "instance": "DEM-1", "name": $0.1, "credits": $0.2,
                 "start": iso.string(from: now.addingTimeInterval(-60 * 86_400)),
                 "end": iso.string(from: now.addingTimeInterval(45 * 86_400))] as [String: Any]
            },
        ]
        try? JSONSerialization.data(withJSONObject: school).write(to: folder.appending(path: "state.json"))

        // This month and the two before, so SPENDING has its heading, something to set it against
        // and a month left behind its button.
        let month = DateFormatter()
        month.dateFormat = "yyyy-MM"
        let spent = [("Groceries & bakeries", 310.0), ("\"Restaurants, fast food & coffee\"", 140),
                     ("Train", 85), ("Bars & pubs", 70), ("Clothes", 60),
                     ("Subscriptions & apps", 45), ("Health", 20)]
        let lines = [0, -1, -2].flatMap { back in
            let id = month.string(from: Calendar.current.date(byAdding: .month, value: back, to: now) ?? now)
            return spent.map { "\(id)-05,-\($0.1 - Double(back) * 15),\($0.0),demo" }
        }
        try? (["date,amount,category,merchant"] + lines).joined(separator: "\n")
            .write(to: folder.appending(path: "payments.csv"), atomically: true, encoding: .utf8)
        let balances = [("Main", 1240.0), ("Livret", 3500), ("PEA", 2150), ("TR", 860)]
            .map { ["name": $0.0, "amount": $0.1, "date": month.string(from: now) + "-05"] as [String: Any] }
        try? JSONSerialization.data(withJSONObject: balances).write(to: folder.appending(path: "balances.json"))

        controller.hub.pretend(mail: mail, todos: todos, school: folder.appending(path: "state.json"))
        controller.money.file = folder.appending(path: "payments.csv")
        // A folder never written: no block of his on a picture meant to be published.
        controller.plugins.folder = folder.appending(path: "blocks")
    }

    /// `--render-demo <dir>`: the README's GIF as frames, plus `list.txt`, ffmpeg's concat list of
    /// how long each stays up. The live panel captured again each time the invented fleet under
    /// it moves; `docs/make-demo.sh` makes the GIF.
    @MainActor
    static func film(_ controller: AppController, panel: NSView, desktop: NSView, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var fleet = controller.sessions
        var list = "", count = 0

        func shot(_ view: NSView, _ seconds: Double, _ caption: String?) {
            for _ in 0 ..< 6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let caption {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let text = NSAttributedString(string: caption, attributes: [
                    .font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.white])
                // Inside the panel's empty lower half, which `make-demo.sh` crops just below.
                // Under the panel's middle, or the middle of the cropped GIF on the bare desktop.
                let mid = view === desktop ? 594 : rep.size.width / 2
                let box = CGRect(x: mid - text.size().width / 2 - 24, y: 300,
                                 width: text.size().width + 48, height: 56)
                NSColor(white: 0, alpha: 0.8).setFill()
                NSBezierPath(roundedRect: box, xRadius: 28, yRadius: 28).fill()
                text.draw(at: CGPoint(x: box.minX + 24, y: box.midY - text.size().height / 2))
                NSGraphicsContext.restoreGraphicsState()
            }
            count += 1
            let name = String(format: "%03d.png", count)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: name))
            list += "file '\(name)'\nduration \(String(format: "%.2f", seconds))\n"
        }
        func show() { controller.pretendFleet = fleet }

        // 0 ready, 1 running, 2 delegated, 3 waiting on an answer; the tile shows its title.
        for (i, title) in ["Dark theme", "Parser fix", "Faster export", "Release v3"].enumerated() {
            fleet[i].transcript?.title = title
        }
        show()
        shot(desktop, 1.4, "You step away for 45 s, or press ⌘⌥L")
        shot(panel, 2.6, "Every Claude Code session, coloured by its state")
        shot(panel, 1.8, "Red: atlas is running a tool")
        fleet[1].state = .ready
        fleet[1].transcript?.hasPendingTool = false
        fleet[1].transcript?.pendingToolNames = []
        fleet[1].transcript?.pendingToolLabels = []
        fleet[1].transcript?.pendingTaskIDs = []
        fleet[1].transcript?.subagents = []
        fleet[1].transcript?.turnOpen = false
        show()
        shot(panel, 2.2, "Green: its turn is over")
        fleet[2].state = .awaitingAnswer
        fleet[2].transcript?.pendingTaskIDs = []
        fleet[2].transcript?.subagents = []
        fleet[2].transcript?.backgroundShellsStartedAt = []
        fleet[2].transcript?.pendingToolNames = ["AskUserQuestion"]
        show()
        shot(panel, 2.4, "Blue: video-code waits for your answer")
        shot(desktop, 1.4, "esc, and back to work")
        // The concat demuxer drops the last frame's duration unless the frame comes again.
        list += "file '\(String(format: "%03d.png", count))'\n"
        try? list.write(to: dir.appending(path: "list.txt"), atomically: true, encoding: .utf8)
        print("wrote \(count) frames and list.txt to \(dir.path)")
    }
}

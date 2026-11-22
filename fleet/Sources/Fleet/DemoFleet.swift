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

        // (gist, sender, action, days ago, starred)
        let mail = [("Invoice for the March sprint", "Ada Quill", "Pay by Friday", -0.2, true),
                    ("Your talk is accepted", "Lantern Conf", "Confirm the slot", -1, false),
                    ("Renewal notice for orchard.dev", "Harbour Domains", "Renew the domain", -3, false)]
            .enumerated().compactMap { index, mail in
                Mail(document("mail/\(index)", ["gist": text(mail.0), "sender": text(mail.1),
                                                "action": text(mail.2), "receivedAt": stamp(mail.3),
                                                "favorite": ["booleanValue": mail.4]]))
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
            .map { ["name": $0.0, "amount": $0.1, "date": month.string(from: now) + "-05",
                    "invested": ["PEA", "TR"].contains($0.0)] as [String: Any] }
        try? JSONSerialization.data(withJSONObject: balances).write(to: folder.appending(path: "balances.json"))

        controller.hub.pretend(mail: mail, todos: todos, school: folder.appending(path: "state.json"))
        controller.money.file = folder.appending(path: "payments.csv")
        controller.launchd.pretend()

        let gb: UInt64 = 1 << 30
        func rows(_ values: [(String, String)]) -> [MemoryDetails.Row] { values.map { .init(name: $0.0, value: $0.1) } }
        controller.reaper.pretend(
            used: 10 * gb, total: 16 * gb, disk: (free: 118_000_000_000, total: 494_000_000_000),
            details: MemoryDetails(kernelZone: 412 << 20, wired: 2 * gb + gb / 2, gpuBusy: 7, gpuMemory: gb + gb / 5,
                                   diskFree: 118_000_000_000, diskTotal: 494_000_000_000,
                                   ram: rows([("Safari", "2.4 GB"), ("claude", "1.9 GB"), ("Xcode", "1.1 GB")]),
                                   cpu: rows([("swift-frontend", "84%"), ("claude", "12%"), ("Safari", "6%")]),
                                   gpu: rows([("WindowServer", "5%"), ("Safari", "2%")])))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        controller.reaper.growth.pretend([("/projects/atlas/.build", 3_400_000_000),
                                          ("/Library/Caches/Homebrew", 1_200_000_000),
                                          ("/Downloads", 700_000_000)].map { .init(path: home + $0.0, bytes: $0.1) },
                                         since: now.addingTimeInterval(-86_400))

        // A block any script can write, here unread chats; the icons are the repo's own.
        let blocks = folder.appending(path: "blocks")
        try? FileManager.default.createDirectory(at: blocks.appending(path: "icons"), withIntermediateDirectories: true)
        let icons = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../blocks/icons").standardized
        let chats = [("Ada Quill", "can you look at the deck?", "whatsapp", "2 min"),
                     ("Lantern crew", "slides due tonight", "discord", "18 min"),
                     ("Sam Orchard", "lunch on Thursday?", "sms", "1 h")]
        for net in Set(chats.map(\.2)) {
            try? FileManager.default.copyItem(at: icons.appending(path: "\(net).png"),
                                              to: blocks.appending(path: "icons/\(net).png"))
        }
        let messages: [String: Any] = ["title": "Messages", "tint": "#3E6FB0", "groups": [[
            "title": "3 unread chats",
            "items": chats.map { ["text": "\($0.0) \u{00B7} \($0.1)", "detail": $0.3, "image": "icons/\($0.2).png"] },
        ]]]
        try? JSONSerialization.data(withJSONObject: messages).write(to: blocks.appending(path: "messages.json"))
        controller.plugins.folder = blocks
    }

    /// `--render-demo <dir>`: the README's GIF as frames, plus `list.txt`, ffmpeg's concat list of
    /// how long each stays up. The live panel captured again each time the invented fleet under
    /// it moves or the pointer goes to another block; `docs/make-demo.sh` makes the GIF. Meant
    /// for `--fake 3,2,1,1/2,1`: four groups on this desktop, two on the next.
    @MainActor
    static func film(_ controller: AppController, panel: NSView, desktop: NSView,
                     rebuild: () -> Void, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var fleet = controller.sessions
        var list = "", count = 0
        var cursor: CGPoint?

        func shot(_ view: NSView, _ seconds: Double, _ caption: String?) {
            for _ in 0 ..< 6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // The offscreen window has no cursor of its own: one is drawn where the hover is.
            if view === panel, let at = cursor {
                let arrow = NSCursor.arrow
                arrow.image.draw(at: CGPoint(x: at.x - arrow.hotSpot.x,
                                             y: view.bounds.height - at.y - arrow.image.size.height + arrow.hotSpot.y),
                                 from: .zero, operation: .sourceOver, fraction: 1)
            }
            if let caption {
                let text = NSAttributedString(string: caption, attributes: [
                    .font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.white])
                // Low in the fleet's empty half, above the crop `make-demo.sh` makes.
                let box = CGRect(x: view.bounds.midX - text.size().width / 2 - 24, y: 330,
                                 width: text.size().width + 48, height: 56)
                NSColor(white: 0, alpha: 0.8).setFill()
                NSBezierPath(roundedRect: box, xRadius: 28, yRadius: 28).fill()
                text.draw(at: CGPoint(x: box.minX + 24, y: box.midY - text.size().height / 2))
            }
            NSGraphicsContext.restoreGraphicsState()
            count += 1
            let name = String(format: "%03d.png", count)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: name))
            list += "file '\(name)'\nduration \(String(format: "%.2f", seconds))\n"
        }
        func show() { controller.pretendFleet = fleet }
        // The block under the pointer, as the `-open` flags and `FLEET_EXPAND` seed it.
        func hover(_ at: CGPoint?, _ flag: String? = nil, expand: String? = nil) {
            CommandLine.arguments.removeAll { $0.hasSuffix("-open") }
            if let flag { CommandLine.arguments.append(flag) }
            if let expand { setenv("FLEET_EXPAND", expand, 1) } else { unsetenv("FLEET_EXPAND") }
            cursor = at
            rebuild()
        }
        func set(_ i: Int, _ state: SessionState, _ title: String) {
            fleet[i].state = state
            fleet[i].transcript?.title = title
        }

        // portfolio 0-2, atlas 3-4, video-code 5, my-hub 6; next desktop: fleet 7-8, siege 9.
        set(0, .ready, "Dark theme"); set(1, .running, "Contact form"); set(2, .delegated, "Image audit")
        set(3, .ready, "Release v3"); set(4, .running, "Parser fix")
        set(5, .apiError, "Faster export")
        set(6, .fresh, "New session")
        set(7, .ready, "Disk gauge"); set(8, .paused, "Docs pass")
        set(9, .running, "Load test")
        show()
        shot(desktop, 1.4, "You step away for 45 s, or press \u{2318}\u{2325}L")
        shot(panel, 2.8, "Every Claude Code session, grouped by project")
        shot(panel, 2.4, "One band per desktop, one colour per state")
        set(4, .ready, "Parser fix")
        show()
        shot(panel, 2.2, "Green: atlas finished its turn")
        set(2, .awaitingAnswer, "Image audit")
        show()
        shot(panel, 2.2, "Blue: portfolio asks you something")

        hover(CGPoint(x: 174, y: 132), "--memory-open")
        shot(panel, 2.8, "MEMORY: kernel, GPU and the top apps")
        hover(CGPoint(x: 174, y: 198), "--disk-open")
        shot(panel, 2.6, "DISK: what grew since yesterday")
        hover(CGPoint(x: 174, y: 263), "--money-open")
        shot(panel, 2.8, "MONEY: spent, saved and invested")
        hover(CGPoint(x: 1337, y: 132), "--mail-open", expand: "mail")
        shot(panel, 2.8, "MAIL under \u{2318}: what to do, starred first")
        hover(CGPoint(x: 1337, y: 198), "--todo-open", expand: "todo")
        shot(panel, 2.6, "TODO under \u{2318}: the phone's list")
        hover(CGPoint(x: 1337, y: 263), expand: "messages.json")
        shot(panel, 2.6, "Any script can add a block: unread chats")
        hover(nil)
        shot(desktop, 1.4, "esc, and back to work")
        // The concat demuxer drops the last frame's duration unless the frame comes again.
        list += "file '\(String(format: "%03d.png", count))'\n"
        try? list.write(to: dir.appending(path: "list.txt"), atomically: true, encoding: .utf8)
        print("wrote \(count) frames and list.txt to \(dir.path)")
    }
}

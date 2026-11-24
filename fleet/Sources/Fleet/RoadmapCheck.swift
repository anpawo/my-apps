import AppKit
import SwiftUI

@MainActor
enum RoadmapCheck {
    private static var failures = 0

    static func run() -> Int32 {
        Firestore.reads = false
        _ = NSApplication.shared
        parsing()
        completion()
        grouping()
        publicationGroups()
        activity()
        ancestorAssignments()
        gestures()
        scrolling()
        RoadmapVisualCheck.run(expect)
        sourceCoverage()
        print(failures == 0 ? "Roadmap checks passed" : "Roadmap checks failed: \(failures)")
        return failures == 0 ? 0 : 1
    }

    private static func expect(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL") \(name)")
        if !condition { failures += 1 }
    }

    private static let source = URL(fileURLWithPath: "/fixture/roadmap.md")

    private static func completion() {
        var step = RoadmapStep(id: "S0", title: "Establish scope", source: source)
        for status in ["Done (source)", "Completed", "Accepted", "Published", "✓ Done", "[x]"] {
            step.status = status
            expect(step.isDone, "ticks explicit completion: \(status)")
        }
        for status in ["Not done", "Unpublished", "Partial; acceptance unverified", "Done; approval pending", "Rendered", "Scheduled", "●", "Status unverified"] {
            step.status = status
            expect(!step.isDone, "does not tick incomplete or ambiguous evidence: \(status)")
        }
    }

    private static func grouping() {
        let text = """
        | Step | Implementation | Track | Status |
        |---|---|---|---|
        | S0 | Define scope | Foundation | Done |
        | S1 | Store records | Foundation | Partial |
        | S2 | Import records | Delivery | Not done |
        """
        let steps = RoadmapParser.steps(text, source: source, kind: .roadmap)
        let snapshot = RoadmapSnapshot(project: RoadmapProject.projects()[1], steps: steps)
        let groups = RoadmapGrouping.groups(snapshot)
        expect(groups.map(\.title) == ["Foundation", "Delivery"] && groups[0].steps.map(\.id) == ["S0", "S1"],
               "combines related source tracks while preserving child order and identifiers")
        expect(groups[0].doneCount == 1 && !groups[0].isDone, "keeps a partially complete group unticked")
        let milestone = text.replacingOccurrences(of: "Track", with: "Other") + """


        | Milestone | Required steps |
        |---|---|
        | Establish foundations | S0\u{2013}S1 |
        | Deliver the import | S2 |
        """
        let grouped = RoadmapParser.steps(milestone, source: source, kind: .roadmap)
        expect(grouped.map(\.group) == ["Establish foundations", "Establish foundations", "Deliver the import"],
               "uses source milestone ranges instead of inventing phase boundaries")
        let log = "- Done: Import source files\n- Done: Import broker files\n- Next: Import another file\n- Done: Repair dashboard filters"
        let progress = RoadmapParser.steps(log, source: source, kind: .progress)
        let progressGroups = RoadmapGrouping.groups(RoadmapSnapshot(project: RoadmapProject.projects()[0], steps: progress))
        expect(progressGroups.count == 2 && progressGroups[0].steps.count == 3 && progressGroups[0].doneCount == 2,
               "combines related progress entries without marking pending work done")
        expect(progressGroups[1].isDone, "ticks a group only when every recorded item is done")
        let session = demoSessions()[0]
        expect(RoadmapActivity.steps(for: session, in: groups[0].steps) == ["S1"],
               "retains live work matching inside grouped steps")
    }

    private static func publicationGroups() {
        let text = "# Publication plan\n## Batch one\n| Task | State |\n|---|---|\n| First clip | Published |\n| Second clip | Rendered |\n\n## Batch two\n| Task | State |\n|---|---|\n| Third clip | Planned |"
        let first = URL(fileURLWithPath: "/fixture/channel-one/PLAN.md")
        let second = URL(fileURLWithPath: "/fixture/channel-two/PLAN.md")
        let steps = RoadmapParser.steps(text, source: first, kind: .publication) + RoadmapParser.steps(text, source: second, kind: .publication)
        let groups = RoadmapGrouping.groups(RoadmapSnapshot(project: RoadmapProject.projects()[3], steps: steps))
        expect(groups.count == 4 && groups[0].steps.count == 2 && groups[0].doneCount == 1,
               "groups publication batches without counting rendered clips as published")
        expect(groups[0].id != groups[2].id, "keeps identically named batches from different source plans separate")
    }

    private static func parsing() {
        let text = """
        # Roadmap
        Local work is partial S1 progress, not acceptance.
        | Step | Implementation | Build days | After |
        |---|---|---|---|
        | G0 | Evidence gate | 1 | None |
        | S0 | Establish scope | 2 | G0 |
        | S1 | Store records safely | 3 | S0 |
        | S2 | Import validated data | 4 | S1 |

        ### S1 Store records safely
        **Goal** Preserve records across restart.
        ### S2 Import validated data
        **Goal** Reject invalid input.
        | S0 | This later table is not another step | 1 | |
        """
        let steps = RoadmapParser.steps(text, source: source, kind: .roadmap)
        expect(steps.map(\.id) == ["G0", "S0", "S1", "S2"], "keeps the first roadmap table in source order including gates")
        expect(steps[2].status == "Partial; acceptance unverified" && steps[1].status == "Status unverified",
               "partial work does not imply phase acceptance or live activity")
        expect(steps[2].detail.contains("Preserve records"), "reads the goal from the matching step section")
        let log = "- Done (Monday): Validate imports\n- Next: Repair storage\n- Blocked: Await review"
        let progress = RoadmapParser.steps(log, source: source, kind: .progress)
        expect(progress.map(\.status) == ["Done (source)", "Next (source)", "Blocked (source)"], "keeps explicit progress log statuses separate")
        let plan = "| Time | Task | Output |\n|---|---|---|\n| Morning | Validate a source | Evidence note |"
        let publication = RoadmapParser.steps(plan, source: source, kind: .publication)
        expect(publication.count == 1 && publication[0].title == "Validate a source", "reads publication tasks without treating table headers as work")
        publicationStates()
        var missing = RoadmapProject.projects()[0]
        missing.sources = [URL(fileURLWithPath: "/fixture/does-not-exist.md")]
        let snapshot = RoadmapSnapshot.read(missing)
        expect(snapshot.steps.isEmpty && snapshot.notices.contains(where: { $0.hasPrefix("Source unavailable") }),
               "shows a missing source without inventing steps")
        expect(RoadmapSnapshot(project: missing, updated: Date().addingTimeInterval(-RoadmapSnapshot.staleAfter - 1)).stale,
               "marks an old source as potentially stale")
    }

    private static func publicationStates() {
        let text = "| # | Date | Clip (original title) | State |\n|---|---|---|---|\n| 1 | Monday | First clip | Published |"
        let steps = RoadmapParser.steps(text, source: source, kind: .publication)
        expect(steps.count == 1 && steps[0].title == "First clip" && steps[0].status == "Published",
               "reads publication state tables using their original column names")
        let video = "| Day | Date | Episode | Video |\n|---|---|---|---|\n| 1 | Monday | Validate the source | clip.mp4 |"
        let episodes = RoadmapParser.steps(video, source: source, kind: .publication)
        expect(episodes.count == 1 && episodes[0].title == "Validate the source",
               "uses episode titles rather than video filenames as publication steps")
    }

    private static func sourceCoverage() {
        let store = RoadmapStore()
        expect(store.loadForPreview(), "waits for actual local source refresh before drawing")
        for snapshot in store.snapshots {
            print("Local source: \(snapshot.project.name), \(RoadmapGrouping.groups(snapshot).count) groups, \(snapshot.steps.count) items, \(snapshot.steps.filter(\.isDone).count) done")
        }
    }

    private static func ancestorAssignments() {
        let project = RoadmapProject.projects()[0]
        var session = demoSessions()[0]
        session.projectAssignment?.path = project.root.deletingLastPathComponent().path
        session.transcript?.cwd = project.root.path
        expect(project.working([session]).count == 1, "counts concrete work below an accepted parent project assignment")
        session.transcript?.cwd = session.projectAssignment?.path
        session.transcript?.projectEvidence.actions = [.init(path: project.root.path + "/feature.py", kind: "edit")]
        expect(project.working([session]).count == 1, "counts completed project edits when the launch folder is the parent")
        session.transcript?.projectEvidence.actions = []
        expect(project.working([session]).isEmpty, "does not treat every parent project session as work on its child")
    }

    private static func activity() {
        let projects = RoadmapProject.projects()
        let steps = demo()[1].steps
        var sessions = demoSessions()
        let working = projects[1].working(sessions)
        let active = working.reduce(into: Set<String>()) { $0.formUnion(RoadmapActivity.steps(for: $1, in: steps)) }
        expect(working.count == 2 && active == ["S1", "S3"], "counts simultaneous working sessions and highlights their separate steps")
        sessions[0].projectAssignment?.path = projects[2].root.path
        expect(projects[1].working(sessions).count == 1 && projects[2].working(sessions).count == 1,
               "uses accepted Fleet assignments ahead of launch folders")
        sessions[0].projectAssignment?.path = nil
        expect(projects[1].working(sessions).count == 1, "does not count an unresolved assignment from its cwd")
        let session = demoSessions()[0]
        var idle = session
        for state in [SessionState.ready, .awaitingAnswer, .apiError, .paused, .fresh] {
            idle.state = state
            expect(projects[1].working([idle]).isEmpty, "does not count idle or blocked sessions: \(state)")
        }
        var ambiguous = session
        ambiguous.context = "Review roadmap"
        ambiguous.transcript?.lastPrompt = "Review roadmap S1 S2 S3"
        expect(RoadmapActivity.steps(for: ambiguous, in: steps).isEmpty, "does not turn a roadmap quotation into live step work")
        ambiguous.context = "Fix a bug"
        ambiguous.transcript?.lastPrompt = "Fix a bug\nThe roadmap mentions S1"
        expect(RoadmapActivity.steps(for: ambiguous, in: steps).isEmpty, "leaves unmatched working agents without a fabricated active step")
    }

    private static func gestures() {
        var swipe = RoadmapSwipe()
        expect(swipe.move(x: -20, y: 1) == nil && swipe.move(x: -60, y: 0) == true,
               "reveals the right page after a leftward horizontal swipe")
        expect(swipe.move(x: 200, y: 0) == nil, "changes pages at most once per physical gesture")
        swipe.reset()
        expect(swipe.move(x: 80, y: 0) == false, "returns to Fleet after the reverse swipe")
        swipe.reset()
        _ = swipe.move(x: 1, y: -15)
        expect(swipe.move(x: -200, y: -15) == nil && swipe.axis == .vertical,
               "a vertical column scroll stays vertical when the fingers drift sideways")
        swipe.reset()
        expect(swipe.move(x: -8, y: -7) == nil && swipe.axis == .vertical,
               "a diagonal vertical scroll does not reveal the dashboard")
        let capture = RoadmapSwipeCapture.Capture { _ in failures += 1 }
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: -200, wheel3: 0)!
        expect(capture.handle(NSEvent(cgEvent: wheel)!) != nil, "an ordinary mouse wheel preserves Fleet interactions")
    }

    private static func scrolling() {
        let store = RoadmapStore()
        store.snapshots = demo()
        let view = RoadmapDashboard(store: store, sessions: demoSessions(), back: {})
        let host = NSHostingView(rootView: view.frame(width: 1280, height: 800))
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        settle()
        let columns = scrollViews(host).filter { $0.documentView != nil }
        expect(columns.count == 4, "creates four independently scrollable project columns")
        guard columns.count == 4 else { return }
        let before = columns.map { $0.contentView.bounds.origin }
        let scrollDistance: CGFloat = 180
        columns[0].contentView.scroll(to: NSPoint(x: before[0].x, y: before[0].y + scrollDistance))
        columns[0].reflectScrolledClipView(columns[0].contentView)
        settle()
        let after = columns.map { $0.contentView.bounds.origin }
        expect(after[0] != before[0] && Array(after.dropFirst()) == Array(before.dropFirst()),
               "scrolling one project preserves the other three positions")
    }

    private static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private static func settle() {
        let settleTime: TimeInterval = 0.5
        RunLoop.main.run(until: Date().addingTimeInterval(settleTime))
    }

    static func demo() -> [RoadmapSnapshot] {
        RoadmapProject.projects().map { project in
            let titles = ["Establish the scope", "Validate source evidence", "Import validated records", "Store records safely", "Review the results", "Exercise failure recovery"]
            let demoStepCount = 22
            let steps = (0..<demoStepCount).map { index in
                RoadmapStep(id: "S\(index)", title: titles[index % titles.count], detail: "Synthetic roadmap evidence for the windowless layout check.",
                            status: index == 0 ? "Done (source)" : index == 1 ? "Partial; acceptance unverified" : "Status unverified",
                            source: source, group: index < 4 ? "Foundation" : "")
            }
            return RoadmapSnapshot(project: project, steps: steps, updated: Date(), notices: ["Synthetic preview"], loaded: true)
        }
    }

    static func demoSessions() -> [Session] {
        let project = RoadmapProject.projects()[1]
        return [1, 3].enumerated().map { index, phase in
            var session = DemoFleet.sessions(1)[0]
            session.runtimeSessionID = "roadmap-fixture-\(index)"
            session.state = .running
            session.context = "Implement S\(phase)"
            session.transcript?.lastPrompt = "Implement S\(phase)"
            session.projectAssignment = ProjectAssignment(path: project.root.path, source: "override", revision: 1,
                                                         catalogueRevision: 1, cwd: session.cwd, fingerprint: "fixture")
            return session
        }
    }
}

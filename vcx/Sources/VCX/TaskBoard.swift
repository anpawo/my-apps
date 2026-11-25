import AppKit
import SwiftUI

/// The right bar: the task of each VCX window on the same project, as its agent wrote it to $VCX_TASK_FILE
/// (asked 2026-11-25: orange working, blue a question for him, green done; a click brings that window up).
struct TaskEntry: Identifiable, Equatable {
    enum State: Equatable { case working, question, done }
    let id: ObjectIdentifier
    let group: String
    let task: String
    let state: State

    var color: Color {
        switch state {
        case .working: Color(red: 0.93, green: 0.5, blue: 0.1)
        case .question: Color(red: 0.2, green: 0.45, blue: 0.9)
        case .done: Color(red: 0.2, green: 0.65, blue: 0.3)
        }
    }
    var label: String { ["working", "waiting for you", "done"][[State.working, .question, .done].firstIndex(of: state)!] }
}

@MainActor
final class TaskBoard: ObservableObject {
    static let shared = TaskBoard()
    static let longestTask = 80
    @Published private(set) var entries: [TaskEntry] = []
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var polling: Task<Void, Never>?

    func start() {
        // Offscreen checks have no app delegate and fill the board themselves.
        guard polling == nil, NSApp?.delegate is AppDelegate else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: progressTick)
            }
        }
    }

    func refresh(_ open: [(window: NSWindow, session: Session)]? = nil) {
        let open = open ?? ((NSApp?.delegate as? AppDelegate)?.windows ?? []).map { ($0.window, $0.session) }
        windows = Dictionary(open.map { (ObjectIdentifier($0.window), $0.window) }) { first, _ in first }
        let next: [TaskEntry] = open.compactMap { window, session in
            guard let task = Self.task(at: session.taskFile) else { return nil }
            return TaskEntry(id: ObjectIdentifier(window), group: Self.group(session), task: task, state: Self.state(session))
        }
        if next != entries { entries = next }
    }

    func show(_ id: ObjectIdentifier) {
        guard let window = windows[id] else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func group(_ session: Session) -> String { URL(fileURLWithPath: session.cwd).resolvingSymlinksInPath().path }

    static func task(at path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        return String(line.prefix(longestTask))
    }

    static func state(_ session: Session) -> TaskEntry.State {
        let lastPrompt = session.rows.lastIndex { $0.kind == "user" } ?? -1
        let answers = session.rows.suffix(from: lastPrompt + 1).filter { $0.kind == "assistant" }.flatMap { $0.items.map(\.text) }
        return state(waiting: !session.permissions.isEmpty || session.needsAttention,
                     busy: session.busy || session.changing || session.backgroundTasks > 0, answers: answers)
    }

    /// Green only once the last answer ends on his Done line; an idle session without one waits on him.
    static func state(waiting: Bool, busy: Bool, answers: [String]) -> TaskEntry.State {
        if waiting { return .question }
        if busy { return .working }
        return answers.last.map { answerParagraphs($0).contains { $0.hasPrefix("✓ Done:") } } == true ? .done : .question
    }
}

struct TaskBar: View {
    @ObservedObject var session: Session
    @ObservedObject private var board = TaskBoard.shared
    private var window: NSWindow? { (NSApp?.delegate as? AppDelegate)?.windows.first { $0.session === session }?.window }

    var body: some View {
        let group = TaskBoard.group(session)
        let entries = board.entries.filter { $0.group == group }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "checklist").frame(width: 12)
                Text("TASKS").tracking(1.2)
                Spacer()
                if !entries.isEmpty { Text("\(entries.count)").font(.system(size: 11, weight: .semibold, design: .monospaced)) }
            }.font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.75)).padding(.horizontal, 22).padding(.vertical, 22)
            Divider().overlay(.black.opacity(0.04))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if entries.isEmpty {
                        Text("No task yet on this project.").font(.system(size: 11)).foregroundStyle(.black.opacity(0.45)).padding(.horizontal, 4).padding(.top, 4)
                    }
                    ForEach(entries) { entry in row(entry, current: window.map { ObjectIdentifier($0) == entry.id } ?? false) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Color.black.opacity(0.025))
            .onAppear { board.start() }
    }

    private func row(_ entry: TaskEntry, current: Bool) -> some View {
        Button { TaskBoard.shared.show(entry.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: entry.state == .done ? "checkmark.circle.fill" : entry.state == .question ? "questionmark.circle.fill" : "ellipsis.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(entry.color)
                Text(entry.task).font(.system(size: 11.5, weight: current ? .semibold : .medium)).lineLimit(3).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.foregroundStyle(.black.opacity(0.8)).padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(entry.color.opacity(current ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(entry.color.opacity(current ? 0.5 : 0.22)))
                .contentShape(Rectangle())
        }.buttonStyle(.reactive).help(current ? "This window: \(entry.label)" : "Bring this session to the front: \(entry.label)")
            .accessibilityLabel("\(entry.task), \(entry.label)")
    }
}

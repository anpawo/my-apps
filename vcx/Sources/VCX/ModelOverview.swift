import SwiftUI

// Opened from the model, token and usage chips: what every VCX window on this Mac runs, and the agents no window uses.
struct ModelOverview: View {
    struct Line: Identifiable { let id: String, window: String, agent: String, model: String, tokens: String, usage: String, current: Bool }
    let currentID: String?
    let changeModel: () -> Void
    @State private var lines: [Line]
    private let live: Bool
    static let refresh: UInt64 = 2_000_000_000

    init(currentID: String?, lines: [Line]? = nil, changeModel: @escaping () -> Void) {
        self.currentID = currentID; self.changeModel = changeModel; live = lines == nil
        _lines = State(initialValue: lines ?? Self.lines(current: currentID))
    }

    static func lines(current: String?) -> [Line] {
        let records = AgentMessages.records()
        var lines = records.compactMap { record -> Line? in
            guard let id = record["sessionId"] as? String, let agent = record["agent"] as? String else { return nil }
            let account = record["account"] as? String ?? ""
            let label = (record["context"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? AgentMessages.title(record["prompt"] as? String ?? "New session")
            return Line(id: id, window: label, agent: name(agent, account),
                        model: record["model"] as? String ?? "", tokens: record["tokens"] as? String ?? "",
                        usage: (record["usage"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "–", current: id == current)
        }.sorted { ($0.current ? 0 : 1, $0.agent, $0.window) < ($1.current ? 0 : 1, $1.agent, $1.window) }
        let used = Set(records.compactMap { record in (record["agent"] as? String).map { $0 + "|" + (record["account"] as? String ?? "") } })
        for account in Settings.shared.candidates("auto") {
            let agent = account.provider == "codex" ? "Codex" : account.provider == "agy" ? "Antigravity" : account.provider.capitalized
            guard !used.contains(agent + "|" + account.name) else { continue }
            lines.append(Line(id: account.id, window: "No window", agent: name(agent, account.name), model: "–", tokens: "–", usage: "–", current: false))
        }
        return lines
    }

    // The default account of a provider goes by the provider's name alone.
    static func name(_ agent: String, _ account: String) -> String { account.isEmpty || account == agent || account.hasPrefix("Default ") ? agent : agent + " · " + account }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Every window on this Mac").font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { ForEach(["Window", "Agent", "Model", "Context", "Usage"], id: \.self) { Text($0).foregroundStyle(.secondary) } }
                Divider()
                ForEach(lines) { line in
                    GridRow {
                        Text(line.window).lineLimit(1).truncationMode(.tail).frame(maxWidth: 220, alignment: .leading)
                        ForEach([line.agent, line.model, line.tokens, line.usage], id: \.self) { Text($0).lineLimit(1).fixedSize() }
                    }.fontWeight(line.current ? .bold : .regular).foregroundStyle(line.window == "No window" ? .secondary : .primary)
                }
            }.font(.system(size: 11, design: .monospaced))
            Button("Change this window's model…", action: changeModel).buttonStyle(.link).font(.system(size: 11))
        }.padding(14).fixedSize()
            .task {
                while live, !Task.isCancelled { lines = Self.lines(current: currentID); try? await Task.sleep(nanoseconds: Self.refresh) }
            }
    }
}

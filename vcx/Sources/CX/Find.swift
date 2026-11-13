import SwiftUI
import AppKit

// ⌘F: finds text in the questions and answers, not in the agent's actions and notes.
// A match is the nth occurrence in one rendered piece of text (a paragraph, a table cell, a code block) of one item.
struct FindMatch: Equatable {
    let item: String
    let fragment: String
    let occurrence: Int
    let fraction: CGFloat
}

@MainActor @Observable final class TranscriptFind {
    var open = false
    var query = ""
    private(set) var matches: [FindMatch] = []
    private(set) var index = 0
    // Bumped on each move, so the current match reports its place again even when it stays in the same text.
    private(set) var serial = 0
    var current: FindMatch? { matches.indices.contains(index) ? matches[index] : nil }
    @ObservationIgnored var reveal: (String) -> Void = { _ in }
    @ObservationIgnored private var cache: [String: (text: String, fragments: [String])] = [:]

    func toggle() { open.toggle(); if !open { query = ""; matches = [] } }

    // Starts at the first match in or after the sections on screen, else at the last one.
    func search(_ rows: [Row], visible: Set<UUID>) {
        let sections = conversationSections(rows)
        let found = collect(sections)
        matches = found.map(\.match)
        let first = sections.firstIndex { visible.contains($0.id) }
        index = first.flatMap { first in found.firstIndex { $0.section >= first } } ?? max(0, matches.count - 1)
        land()
    }

    // New text while open: the count follows it and the current match stays where it was.
    func refresh(_ rows: [Row]) {
        let kept = current
        matches = collect(conversationSections(rows)).map(\.match)
        index = kept.flatMap { kept in matches.firstIndex(of: kept) } ?? min(index, max(0, matches.count - 1))
    }

    func move(_ step: Int) {
        guard !matches.isEmpty else { return }
        index = (index + step + matches.count) % matches.count
        land()
    }

    private func land() {
        serial += 1
        if let current { reveal(current.item) }
    }

    private func collect(_ sections: [ConversationSection]) -> [(section: Int, match: FindMatch)] {
        guard !query.isEmpty else { return [] }
        var found: [(Int, FindMatch)] = []
        for (n, section) in sections.enumerated() {
            let question = section.question.flatMap { $0.kind == "user" ? $0.items.first : nil }, answer = sectionParts(section.rows).last?.items.first
            for (item, user) in [(question, true), (answer, false)] {
                guard let item else { continue }
                for fragment in fragments(item, user: user) {
                    let ranges = findRanges(of: query, in: fragment), length = max(1, fragment.count)
                    for (k, range) in ranges.enumerated() {
                        found.append((n, FindMatch(item: item.id, fragment: fragment, occurrence: k, fraction: CGFloat(fragment.distance(from: fragment.startIndex, to: range.lowerBound)) / CGFloat(length))))
                    }
                }
            }
        }
        return found
    }

    private func fragments(_ item: Item, user: Bool) -> [String] {
        let text = user ? userText(item) : item.text
        if let hit = cache[item.id], hit.text == text { return hit.fragments }
        let pieces = user ? userFragments(item) : proseFragments(text.isEmpty ? "…" : text)
        cache[item.id] = (text, pieces)
        return pieces
    }

    private func userText(_ item: Item) -> String { ((item.data["content"] as? [JSON]) ?? []).compactMap { $0["text"] as? String }.joined() }

    private func userFragments(_ item: Item) -> [String] {
        if let message = AgentMessages.parse(userText(item)) { return [message.body] }
        return ((item.data["content"] as? [JSON]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
    }
}

// The text MarkdownBody shows, piece by piece in its order; keep in step with ProseView and CodeBlock.
func proseFragments(_ text: String) -> [String] {
    markdownBlocks(text).flatMap { block -> [String] in
        if block.code { return block.markdown ? proseFragments(block.text) : [block.text] }
        return answerParagraphs(block.text).flatMap { paragraph -> [String] in
            let lines = paragraph.components(separatedBy: "\n")
            let sources: [String]
            if lines.count >= 2, tableRule(lines[1]) { sources = lines.enumerated().filter { $0.offset != 1 }.flatMap { tableCells($0.element) } }
            else if paragraph.hasPrefix("#") { sources = [String(paragraph.drop(while: { $0 == "#" || $0 == " " }))] }
            else if paragraph.hasPrefix("⟶ ") || paragraph.hasPrefix("✓ Done:") { sources = [answerLine(paragraph)] }
            else { sources = [paragraph] }
            return sources.map { String(richText($0).characters) }
        }
    }
}

func answerLine(_ paragraph: String) -> String {
    paragraph.replacingOccurrences(of: "⟶ Next:", with: "+ Next:").replacingOccurrences(of: "⟶ ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func richText(_ text: String) -> AttributedString { (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text) }

func findRanges(of query: String, in text: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = [], start = text.startIndex
    while let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex), !range.isEmpty {
        ranges.append(range); start = range.upperBound
    }
    return ranges
}

let findColor = Color(red: 1, green: 0.9, blue: 0.4), findCurrentColor = Color(red: 1, green: 0.62, blue: 0.2)

// Which item the text below belongs to, and where the table row holding it wants the current match's place.
private struct FindItemKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct FindLandedKey: EnvironmentKey { static let defaultValue: ((CGFloat) -> Void)? = nil }
extension EnvironmentValues {
    var findItem: String? { get { self[FindItemKey.self] } set { self[FindItemKey.self] = newValue } }
    var findLanded: ((CGFloat) -> Void)? { get { self[FindLandedKey.self] } set { self[FindLandedKey.self] = newValue } }
}

extension TranscriptFind {
    func currentIn(_ item: String?, _ fragment: String) -> FindMatch? {
        guard open, let current, current.item == item, current.fragment == fragment else { return nil }
        return current
    }

    // Tints each match in `text`, whose characters are `fragment`; the current one darker.
    func highlight(_ text: AttributedString, fragment: String, item: String?) -> AttributedString {
        guard open, !query.isEmpty, item != nil else { return text }
        var text = text, start = text.startIndex, n = 0
        let current = currentIn(item, fragment)?.occurrence
        while start < text.endIndex, let range = text[start...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]), !range.isEmpty {
            text[range].backgroundColor = n == current ? findCurrentColor : findColor
            start = range.upperBound; n += 1
        }
        return text
    }
}

// Put behind a text holding the current match: tells its row where the match is, once per move.
struct FindMarker: ViewModifier {
    let find: TranscriptFind?
    let item: String?
    let fragment: String
    @Environment(\.findLanded) private var landed
    func body(content: Content) -> some View {
        content.background {
            if let find, let match = find.currentIn(item, fragment), let landed {
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("conversation")).minY + $0.size.height * match.fraction } action: { landed($0) }
                    .id(find.serial)
            }
        }
    }
}

struct FindBar: View {
    @Bindable var find: TranscriptFind
    let search: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black.opacity(0.45))
            TextField("Find in conversation", text: $find.query)
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).frame(width: 200)
                .focused($focused)
                .onSubmit { find.move(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1); focused = true }
                .onChange(of: find.query) { search() }
            Text(find.query.isEmpty ? "" : find.matches.isEmpty ? "No match" : "\(find.index + 1) of \(find.matches.count)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.black.opacity(0.5)).monospacedDigit().fixedSize()
            Button { find.move(-1) } label: { Image(systemName: "chevron.up").frame(width: 18, height: 18).contentShape(Rectangle()) }
                .buttonStyle(.reactive(RoundedRectangle(cornerRadius: 5), outset: 2)).help("Previous match (Shift Return)").disabled(find.matches.isEmpty)
            Button { find.move(1) } label: { Image(systemName: "chevron.down").frame(width: 18, height: 18).contentShape(Rectangle()) }
                .buttonStyle(.reactive(RoundedRectangle(cornerRadius: 5), outset: 2)).help("Next match (Return)").disabled(find.matches.isEmpty)
            Button(action: close) { Image(systemName: "xmark").frame(width: 18, height: 18).contentShape(Rectangle()) }
                .buttonStyle(.reactive(RoundedRectangle(cornerRadius: 5), outset: 2)).help("Close (Escape)")
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.black.opacity(0.6))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10)).raised(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black.opacity(0.1)))
        .onAppear { focused = true }
    }
}

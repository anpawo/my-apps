import SwiftUI
import AppKit

// The transcript is an NSTableView, as Mail's message list is: one row per question, per exchange and per spacer, each an
// NSHostingView of the SwiftUI row. SwiftUI's LazyVStack spun the main thread in its own prefetch (11-10: 17,000 layout
// transactions a second with no VCX callback in them); a List measured every row up front (1 s to open 21 exchanges).
// Rows are measured once they come near the viewport; the others keep an estimate, and the rows above the viewport absorb
// the difference so what is shown stays put.

@MainActor final class TranscriptGeometry: ObservableObject {
    // Each shown question's top in the viewport, for the question pinned above the transcript.
    @Published var questionTops: [UUID: CGFloat] = [:]
}

// Read live by the rows, so the toggle's animation reaches every block it opens: a new root view would show them open at once.
@MainActor final class TranscriptDetails: ObservableObject {
    @Published var on = false
}

private struct LiveDetails<Content: View>: View {
    @ObservedObject var details: TranscriptDetails
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(details.on) }
}

enum TranscriptKey: Hashable { case top, empty, question(UUID), exchange(UUID), bottom }

struct TranscriptTable: NSViewRepresentable {
    let session: Session
    // Compared by SwiftUI to call updateNSView when one of them changes.
    let rows: [Row]
    let revision: Int
    let details: Bool
    let replacing: Bool
    let sending: SendAnimation
    let geometry: TranscriptGeometry
    let reduceMotion: Bool
    func makeCoordinator() -> TranscriptController { TranscriptController() }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.attach(self) }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.details.on != details { withTransaction(context.transaction) { context.coordinator.toggle(details) } }
        context.coordinator.update()
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: TranscriptController) { coordinator.detach() }
}

final class TranscriptScrollView: NSScrollView {
    weak var controller: TranscriptController?
    override func tile() { super.tile(); controller?.resized() }
    override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event); controller?.userScrolled() }
}

final class TranscriptTableView: NSTableView {
    // Clicking the transcript leaves the composer focused, as the SwiftUI scroll view did; selectable text still takes focus.
    override var acceptsFirstResponder: Bool { false }
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}

final class TranscriptCell: NSView {
    let host: NSHostingController<AnyView>
    // The row's natural height: the hosting view keeps it and stays pinned to the top while the row animates to it.
    var contentHeight: CGFloat = 0 { didSet { if contentHeight != oldValue { needsLayout = true } } }
    init(_ view: AnyView) {
        host = NSHostingController(rootView: view)
        host.sizingOptions = []
        super.init(frame: .zero)
        // Growing content shows as its row opens, not over the rows below.
        clipsToBounds = true
        addSubview(host.view)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        // ponytail: in 2048 pt steps, so a block opening rarely resizes it; resized during the opening animation, the hosting view
        // drew its old content lower by half the growth for a few frames. Content keeps to the top, the cell clips the rest.
        let natural = contentHeight > 0 ? contentHeight : bounds.height
        host.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: (floor(natural / 2048) + 1) * 2048)
    }
    // Asked for no height, the root's flexible frame takes its content's.
    func measure(width: CGFloat) -> CGFloat { ceil(host.sizeThatFits(in: CGSize(width: width, height: 0)).height) }
}

@MainActor
final class TranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var parent: TranscriptTable!
    let scroll = TranscriptScrollView()
    let table = TranscriptTableView()
    private var clip: NSClipView { scroll.contentView }
    private var keys: [TranscriptKey] = []
    private var index: [TranscriptKey: Int] = [:]
    private var sections: [UUID: ConversationSection] = [:]
    private var lastSection: UUID?
    private var signatures: [TranscriptKey: [AnyHashable]] = [:]
    private var cells: [TranscriptKey: TranscriptCell] = [:]
    // Heights measured at `width`; a stale one is still the best estimate until its row is measured again.
    private var heights: [TranscriptKey: CGFloat] = [:]
    private var stale: Set<TranscriptKey> = []
    private var width: CGFloat = 0
    private var revision: Int?
    private var updating = false
    // Rows that change height shortly after new content keep the end in view; a block opened later grows in place, as before.
    private var followUntil = Date.distantPast
    private var endAnimating = false
    let details = TranscriptDetails()
    private var adjusting = false
    private var publishing = false
    private var localFrames: [TranscriptKey: [String: CGRect]] = [:]
    // A table SwiftUI dropped must not write its session's geometry over the table that replaced it.
    private var detached = false

    func attach(_ parent: TranscriptTable) -> NSScrollView {
        self.parent = parent
        details.on = parent.details
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self; table.delegate = self
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.controller = self
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(userScrolled), name: NSScrollView.didLiveScrollNotification, object: scroll)
        let session = parent.session
        session.scrollToExchange = { [weak self] in self?.scroll(to: .exchange($0), bottom: false, animated: false) }
        session.landOnEnd = { [weak self] in session.follow.attached = true; self?.scrollToEnd(animated: false) }
        sync()
        return scroll
    }

    func detach() {
        detached = true
        NotificationCenter.default.removeObserver(self)
        scroll.controller = nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { keys.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(keys[row]) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { cell(keys[row]) ?? NSView() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private func height(_ key: TranscriptKey) -> CGFloat {
        switch key {
        case .top: return 28
        // Holds the bottom padding so following lands where a manual scroll ends.
        case .bottom: return 29
        default: return heights[key] ?? estimate(key)
        }
    }

    // ponytail: a rough guess from text length (7 pt a character, 18 pt a line); measured rows replace it as they come near.
    private func estimate(_ key: TranscriptKey) -> CGFloat {
        let columns = max(20, (width > 50 ? width - 48 : 900) / 7.3)
        func lines(_ text: String) -> CGFloat { text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, ceil(CGFloat($1.count) / columns)) } }
        switch key {
        case .empty: return 330
        case .question(let id):
            let text = sections[id]?.question?.items.first.map { (($0.data["content"] as? [JSON]) ?? []).compactMap { $0["text"] as? String }.joined() } ?? ""
            let shown = lines(text)
            return (shown > 15 ? 2 : shown) * 15 + 56
        case .exchange(let id):
            guard let rows = sections[id]?.rows else { return 100 }
            let parts = sectionParts(rows)
            return (parts.trail.isEmpty ? 0 : 64) + (parts.last.map { 51 + lines($0.items.first?.text ?? "") * 18 } ?? 0) + CGFloat(parts.notices.count) * 40 + 24
        default: return height(key)
        }
    }

    private func cell(_ key: TranscriptKey) -> TranscriptCell? {
        if let cell = cells[key] { return cell }
        guard let content = content(key) else { return nil }
        let cell = TranscriptCell(content)
        cells[key] = cell
        return cell
    }

    private func content(_ key: TranscriptKey) -> AnyView? {
        let session = parent.session
        switch key {
        case .top, .bottom: return nil
        case .empty:
            return root(key, VStack(spacing: 16) {
                Image(systemName: "sparkle").font(.system(size: 40, weight: .light)).foregroundStyle(accent)
                Text("A clear space to build.").font(.system(size: 28, weight: .semibold))
                Text("Your code, your agents, one conversation.").font(.system(size: 14)).foregroundStyle(.black.opacity(0.6))
            }.frame(maxWidth: .infinity).padding(.vertical, 100).padding(.bottom, 24))
        case .question(let id):
            guard let section = sections[id], let question = section.question else { return nil }
            let closesUp = section.rows.isEmpty && section.id != lastSection
            return root(key, ConversationRow(row: question, session: session, collapsible: true).equatable().padding(.bottom, closesUp ? 8 : 24))
        case .exchange(let id):
            guard let section = sections[id] else { return nil }
            let parts = sectionParts(section.rows), sent = parts.notices.filter { $0.kind == "peer" }
            let top: (CGFloat) -> CGFloat = { [weak self] in (self?.top(of: key) ?? 0) + $0 }
            let reduceMotion = parent.reduceMotion
            return root(key, LiveDetails(details: details) { on in VStack(alignment: .leading, spacing: 24) {
                if !parts.trail.isEmpty {
                    WorkBlock(rows: parts.trail, details: on, reveal: { [weak self] in self?.scroll(to: section.question == nil ? key : .question(id), bottom: false, animated: !reduceMotion) }, viewportTop: top)
                }
                if let last = parts.last { ConversationRow(row: last, session: session).equatable() }
                if !sent.isEmpty {
                    WorkBlock(rows: sent, details: on, reveal: { [weak self] in self?.scroll(to: key, bottom: parts.last != nil, animated: !reduceMotion) }, viewportTop: top)
                }
                ForEach(parts.notices.filter { $0.kind == "notice" }) { row in ConversationRow(row: row, session: session).equatable() }
            }.padding(.bottom, 24) })
        }
    }

    private func root(_ key: TranscriptKey, _ content: some View) -> AnyView {
        AnyView(content.padding(.horizontal, 24)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { [weak self] in self?.grew(key, to: $0) }
            // At the top of a row grown before its content: a hosting view centers what is smaller than itself.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A send flight lands on the bubble's frame, measured in its row and placed in the window by the table.
            .coordinateSpace(name: "conversation")
            .onPreferenceChange(MessageFrames.self) { [weak self] in self?.framesChanged(key, $0) }
            // Row-local frames also reach the window's own preference, where the flight read them as conversation frames.
            .transformPreference(MessageFrames.self) { $0 = [:] }
            .environmentObject(parent.sending)
            .disabled(parent.replacing)
            .fontDesign(.monospaced)
            .foregroundStyle(.black.opacity(0.92))
            .environment(\.colorScheme, .light))
    }

    // MARK: Updates

    // In SwiftUI's update, so a sent message has its row, and its flight, in the frame that clears the composer: one turn
    // later it vanished for a frame or two. Rows measure in hosting views of their own; what publishes waits for the next turn.
    // What opens grows in place, as it did in the scroll view, even right after new content.
    func toggle(_ on: Bool) {
        followUntil = .distantPast
        details.on = on
    }

    func update() {
        updating = true; sync(); updating = false
    }

    func sync() {
        guard !detached else { return }
        let session = parent.session
        let all = conversationSections(session.rows)
        var next: [TranscriptKey] = [.top], signatures: [TranscriptKey: [AnyHashable]] = [:]
        if session.rows.isEmpty { next.append(.empty); signatures[.empty] = [parent.replacing] }
        sections = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        lastSection = all.last?.id
        for section in all {
            if section.question != nil {
                next.append(.question(section.id))
                signatures[.question(section.id)] = [section.rows.isEmpty && section.id != lastSection, parent.replacing]
            }
            if !section.rows.isEmpty {
                next.append(.exchange(section.id))
                signatures[.exchange(section.id)] = section.rows.map(\.id) + [parent.replacing]
            }
        }
        next.append(.bottom)
        for (key, signature) in signatures where self.signatures[key].map({ $0 != signature }) == true {
            if let cell = cells[key], let view = content(key) { cell.host.rootView = view }
            stale.insert(key)
        }
        self.signatures = signatures
        if next != keys {
            let kept = Set(next)
            for key in Set(keys).subtracting(kept) { cells[key] = nil; heights[key] = nil; localFrames[key] = nil; stale.remove(key) }
            keys = next
            index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
            adjusting = true; table.reloadData(); adjusting = false
        }
        let follow = revision != session.revision
        revision = session.revision
        if follow && session.follow.attached { followUntil = Date() + 0.5; scrollToEnd(animated: !parent.reduceMotion && (parent.sending.hasPending || parent.sending.flight != nil)) }
        else { measure(near: clip.bounds) }
        updateGeometry()
    }

    // MARK: Measuring

    // Measures the rows that have no height at this width, and returns those whose height changed.
    private func remeasure(_ rows: some Sequence<Int>) -> IndexSet {
        var changed = IndexSet()
        guard width > 50 else { return changed }
        for row in rows where keys.indices.contains(row) {
            let key = keys[row]
            guard heights[key] == nil || stale.contains(key), let cell = cell(key) else { continue }
            let measured = cell.measure(width: width), before = height(key)
            stale.remove(key); heights[key] = measured; cell.contentHeight = measured
            if measured != before { changed.insert(row) }
        }
        return changed
    }

    // New heights keep what the viewport shows in place: rows above it absorb the difference (and, for rows only measured now,
    // the row crossing its top edge too), while a transcript following its end stays on it.
    private func apply(_ rows: IndexSet, crossing: Bool, animated: Bool = false) {
        guard !rows.isEmpty else { return }
        let visible = clip.bounds, atEnd = parent.session.follow.attached && Date() < followUntil && (endAnimating || contentHeight - visible.maxY < 1)
        var shift: CGFloat = 0
        for row in rows {
            let old = table.rect(ofRow: row)
            if crossing ? old.minY < visible.minY : old.maxY <= visible.minY { shift += height(keys[row]) - old.height }
        }
        let wasAdjusting = adjusting
        adjusting = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !atEnd && shift == 0 ? (parent.reduceMotion ? 0.1 : 0.25) : 0
            context.allowsImplicitAnimation = false
            table.noteHeightOfRows(withIndexesChanged: rows)
        }
        // Rows shorter than their estimate can leave the origin past the new end: setOrigin brings it back.
        if atEnd { setOrigin(end, duration: endAnimating ? 0.25 : 0) } else if shift != 0 || visible.minY > end { setOrigin(visible.minY + shift) }
        adjusting = wasAdjusting
    }

    private func measure(near rect: CGRect) {
        let range = table.rows(in: rect.insetBy(dx: 0, dy: -rect.height / 2))
        apply(remeasure(range.location..<range.location + range.length), crossing: true)
    }

    // A row's own content changed height (an answer streaming, a block opening).
    private func grew(_ key: TranscriptKey, to height: CGFloat) {
        FreezeTrace.note("transcript row height")
        guard width > 50, let row = index[key], let cell = cells[key], !stale.contains(key) || heights[key] == nil else { return }
        // Measured at another width, the row reports its new height once laid out at this one: it is measured again instead.
        guard abs(cell.host.view.frame.width - width) < 0.5 || cell.host.view.frame.width == 0 else { return }
        cell.contentHeight = height
        guard abs(height - (heights[key] ?? 0)) >= 0.5 else { return }
        heights[key] = height
        apply([row], crossing: false, animated: true)
        updateGeometry()
        publishFrames()
    }

    func resized() {
        let new = clip.bounds.width
        guard abs(new - width) >= 0.5, !adjusting else { return }
        let visible = clip.bounds, first = table.rows(in: visible).location
        let anchor = keys.indices.contains(first) ? (row: first, offset: table.rect(ofRow: first).minY - visible.minY) : nil
        width = new
        stale = Set(heights.keys)
        adjusting = true
        table.sizeLastColumnToFit()
        let follow = parent.session.follow.attached
        // The rows that will show: from the last one up when following, else from the one at the top edge down.
        var covered: CGFloat = 0, row = follow ? keys.count - 1 : anchor?.row ?? 0
        while keys.indices.contains(row), covered < visible.height {
            _ = remeasure([row]); covered += height(keys[row]); row += follow ? -1 : 1
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<keys.count))
        }
        if follow { setOrigin(end) }
        else if let anchor { setOrigin(table.rect(ofRow: anchor.row).minY - anchor.offset) }
        adjusting = false
        measure(near: clip.bounds)
        updateGeometry()
    }

    // MARK: Scrolling

    private var contentHeight: CGFloat { keys.isEmpty ? 0 : table.rect(ofRow: keys.count - 1).maxY }
    private var end: CGFloat { max(0, contentHeight - clip.bounds.height) }

    private func setOrigin(_ y: CGFloat, duration: Double = 0) {
        let target = NSPoint(x: 0, y: min(max(0, y), end)), toEnd = abs(target.y - end) < 1
        if duration > 0 {
            if toEnd { endAnimating = true }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(target)
            } completionHandler: { [weak self] in
                guard let self else { return }
                self.scroll.reflectScrolledClipView(self.clip)
                // The end may have moved while it scrolled there (a row measured, an answer grown).
                if toEnd { self.endAnimating = false; if self.parent.session.follow.attached { self.setOrigin(self.end) } }
            }
        } else {
            clip.scroll(to: target)
        }
        scroll.reflectScrolledClipView(clip)
    }

    // Measures the rows the end shows, from the last one up, so it lands on the real end.
    func scrollToEnd(animated: Bool) {
        var row = keys.count - 1, covered: CGFloat = 0
        while row >= 0, covered < clip.bounds.height { apply(remeasure([row]), crossing: true); covered += height(keys[row]); row -= 1 }
        setOrigin(end, duration: animated ? 0.42 : 0)
        updateGeometry()
    }

    func scroll(to key: TranscriptKey, bottom: Bool, animated: Bool) {
        guard let target = index[key] else { return }
        var row = target, covered: CGFloat = 0
        while keys.indices.contains(row), covered < clip.bounds.height { apply(remeasure([row]), crossing: true); covered += height(keys[row]); row += bottom ? -1 : 1 }
        let rect = table.rect(ofRow: target)
        setOrigin(bottom ? rect.maxY - clip.bounds.height : rect.minY, duration: animated ? 0.3 : 0)
        updateGeometry()
    }

    private func top(of key: TranscriptKey) -> CGFloat? { index[key].map { table.rect(ofRow: $0).minY - clip.bounds.minY } }

    @objc private func scrolled() {
        guard !adjusting else { return }
        FreezeTrace.note("transcript scroll")
        measure(near: clip.bounds)
        // However it got there (the scroller, End, a restored offset), the end follows again; only the user's scroll leaves it.
        if !parent.session.follow.attached, !updating, contentHeight - clip.bounds.maxY < 40 { userScrolled() }
        updateGeometry()
        if parent.sending.hasPending || parent.sending.flight != nil { publishFrames() }
    }

    @objc func userScrolled() {
        FreezeTrace.note("transcript user scroll")
        parent.session.userScroll(distance: max(0, contentHeight - clip.bounds.maxY))
    }

    // MARK: Geometry

    private func updateGeometry() {
        guard !detached else { return }
        let session = parent.session, visible = clip.bounds, range = table.rows(in: visible)
        var questions: [UUID: CGFloat] = [:], exchanges: [UUID: CGFloat] = [:]
        for row in range.location..<range.location + range.length where keys.indices.contains(row) {
            let top = table.rect(ofRow: row).minY - visible.minY
            switch keys[row] {
            case .question(let id): questions[id] = top
            case .exchange(let id): exchanges[id] = top
            default: break
            }
        }
        session.questionTops = questions; session.exchangeTops = exchanges
        if session.drawnRows != range.length { session.drawnRows = range.length; FreezeTrace.shape(of: session) }
        // Published from a run loop turn of its own: a resize reaches here inside SwiftUI's layout.
        guard !publishing else { return }
        publishing = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishing = false
            let session = self.parent.session
            session.pinQuestion()
            if self.parent.geometry.questionTops != session.questionTops { self.parent.geometry.questionTops = session.questionTops }
        }
    }

    private func framesChanged(_ key: TranscriptKey, _ frames: [String: CGRect]) {
        FreezeTrace.note("transcript row frames")
        localFrames[key] = frames.isEmpty ? nil : frames
        publishFrames()
    }

    // The bubbles' frames in the conversation's space, for the send flight.
    private func publishFrames() {
        guard !detached else { return }
        if updating { DispatchQueue.main.async { [weak self] in self?.publishFrames() }; return }
        guard !localFrames.isEmpty else { return }
        let origin = parent.sending.transcript.origin, visible = clip.bounds
        var all: [String: CGRect] = [:]
        for (key, frames) in localFrames {
            guard let row = index[key] else { continue }
            let rect = table.rect(ofRow: row)
            for (name, frame) in frames { all[name] = name.hasPrefix("collapsed:") ? frame : frame.offsetBy(dx: origin.x + rect.minX - visible.minX, dy: origin.y + rect.minY - visible.minY) }
        }
        let session = parent.session
        parent.sending.receive(all, rows: { session.rows }, reduceMotion: parent.reduceMotion)
    }
}

// The question whose exchange runs under the top edge stays there, as a pinned header did: same place, width and look,
// and the next question pushes it up. Unpinned, it follows its own row back down while its shadow fades, as the header did.
struct PinnedQuestion: View {
    @ObservedObject var session: Session
    @ObservedObject var geometry: TranscriptGeometry
    @State private var unpinning: UUID?
    var body: some View {
        GeometryReader { proxy in
            let ids = [unpinning, session.pinnedQuestion].compactMap { $0 }.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
            ZStack(alignment: .top) {
                ForEach(ids, id: \.self) { id in
                    if let row = session.rows.last(where: { $0.id == id }), headsSection(row) {
                        let own = geometry.questionTops[id] ?? -.infinity
                        let next = geometry.questionTops.values.filter { $0 > own }.min() ?? .infinity
                        ConversationRow(row: row, session: session, collapsible: true, pinnedIn: proxy.size, lifted: id == session.pinnedQuestion).equatable()
                            .padding(.horizontal, 24)
                            .alignmentGuide(.top) { own >= 0 ? -own : max(0, $0.height - (next - 24)) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
        .onChange(of: session.pinnedQuestion) { old, _ in
            guard let old else { return }
            unpinning = old
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if unpinning == old { unpinning = nil } }
        }
    }
}

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct AppEntry: Identifiable, Equatable {
    let path: String
    let name: String
    var id: String { path }
}

/// The apps, read from the folders they live in rather than from Spotlight's index: it works with indexing off, and
/// an app installed a minute ago is there the next time the panel opens. A hundred names take under a millisecond.
enum Catalog {
    static let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                          "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]

    static func apps(in folders: [String] = folders) -> [AppEntry] {
        let fm = FileManager.default
        let paths = folders.flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }.map { "\(dir)/\($0)" }
        } + ["/System/Library/CoreServices/Finder.app"]
        var seen = Set<String>()
        return paths.compactMap { path in
            var name = fm.displayName(atPath: path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            return seen.insert(name).inserted ? AppEntry(path: path, name: name) : nil
        }
    }
}

enum Rank {
    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// Lower ranks first, nil is no match: the start of the name, the start of a word in it, its initials ("vsc" for
    /// Visual Studio Code), anywhere in it, then its letters in order.
    static func tier(_ query: String, _ name: String) -> Int? {
        let q = fold(query), n = fold(name)
        if n.hasPrefix(q) { return 0 }
        let words = n.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(q) }) { return 1 }
        if String(words.compactMap(\.first)).hasPrefix(q) { return 2 }
        if n.contains(q) { return 3 }
        var rest = Substring(q)
        for c in n where c == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty ? 4 : nil
    }

    /// Within a tier, the app opened most often from here comes first, then the shorter name.
    static func matches(_ query: String, in apps: [AppEntry], uses: [String: Int]) -> [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return apps.compactMap { app in tier(q, app.name).map { (app: app, tier: $0, uses: uses[app.path] ?? 0) } }
            .sorted { ($0.tier, -$0.uses, $0.app.name.count, $0.app.name) < ($1.tier, -$1.uses, $1.app.name.count, $1.app.name) }
            .map(\.app)
    }
}

@MainActor
final class Opener: ObservableObject {
    static let width: CGFloat = 600
    static let rows = 8
    /// Room around the box for its shadow: the panel itself is clear, the box sits at its top.
    static let margin: CGFloat = 40
    static var size: NSSize { NSSize(width: width + 2 * margin, height: 56 + 13 + CGFloat(rows) * 42 + 2 * margin) }

    @Published private(set) var query = ""
    @Published private(set) var results: [AppEntry] = []
    @Published private(set) var index = 0
    var apps: [AppEntry] = []
    private var panel: OpenerPanel?
    private static var icons: [String: NSImage] = [:]

    var uses: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "uses") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "uses") }
    }

    func type(_ text: String) {
        query = text
        results = Array(Rank.matches(text, in: apps, uses: uses).prefix(Self.rows))
        index = 0
    }

    /// Every key comes here before any view. There is no text field: in a panel that never activates the app there
    /// would be one to focus, and a field that missed its focus would leave the typing nowhere.
    func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Escape: hide()
        case kVK_Return, kVK_ANSI_KeypadEnter: if results.indices.contains(index) { open(results[index]) }
        case kVK_DownArrow where !results.isEmpty: index = (index + 1) % results.count
        case kVK_UpArrow where !results.isEmpty: index = (index + results.count - 1) % results.count
        case kVK_Delete: type(flags.contains(.command) || flags.contains(.option) ? "" : String(query.dropLast()))
        default:
            // Arrows and function keys come as characters of the private-use area.
            guard flags.intersection([.command, .control]).isEmpty, let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
            else { return false }
            type(query + text)
        }
        return true
    }

    func open(_ app: AppEntry) {
        uses[app.path, default: 0] += 1
        hide()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
    }

    func toggle() {
        if panel?.isVisible == true { return hide() }
        apps = Catalog.apps()
        type("")
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.setFrame(Self.frame(in: screen.visibleFrame), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// The box's top a fifth of the way down, where Spotlight puts its bar.
    static func frame(in area: NSRect) -> NSRect {
        NSRect(x: area.midX - size.width / 2, y: area.maxY - area.height / 5 + margin - size.height, width: size.width, height: size.height)
    }

    func hide() { panel?.orderOut(nil) }

    static func icon(_ path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// Non-activating, as Spotlight: it takes the keys without taking the app in front away.
    private func makePanel() -> OpenerPanel {
        let panel = OpenerPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onKey = { [weak self] in self?.key($0) ?? false }
        let host = NSHostingView(rootView: OpenerView(opener: self))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

final class OpenerPanel: NSPanel {
    var onKey: (NSEvent) -> Bool = { _ in false }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey(event) { return }
        super.sendEvent(event)
    }

    /// A click anywhere else puts it away, as Spotlight does.
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

struct OpenerView: View {
    @ObservedObject var opener: Opener
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 1) {
                    Text(opener.query)
                    // A caret that does not blink: a blink would redraw the panel twice a second for nothing.
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: 26)
                    if opener.query.isEmpty { Text("Open an app").foregroundStyle(.tertiary).padding(.leading, 4) }
                }
                .font(.system(size: 24))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            if !opener.results.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(opener.results.enumerated()), id: \.element.id) { i, app in
                        row(app, selected: i == opener.index)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: Opener.width)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .padding(Opener.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ app: AppEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: Opener.icon(app.path)).resizable().frame(width: 28, height: 28)
            Text(app.name).font(.system(size: 15))
            Spacer(minLength: 0)
            if selected { Text("↵").font(.system(size: 14)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { opener.open(app) }
    }
}

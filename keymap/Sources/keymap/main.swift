import AppKit
import SwiftUI

enum Kind: String {
    case mine = "Mine, global", macLive = "macOS, on this Mac", inMyApps = "In my apps", often = "Used often"
    case macOS = "macOS, in every app", apps = "Most apps' menus", text = "Text fields"
    var color: Color {
        switch self {
        case .mine: .green; case .macLive, .macOS: .red; case .inMyApps: .purple; case .often: .gray
        case .apps: .orange; case .text: .blue
        }
    }
    static let mineTab: [Kind] = [.mine, .macLive, .inMyApps, .often]
    static let defaultsTab: [Kind] = [.macOS, .apps, .text]
}

struct Shortcut { let mods: String; let key: String; let label: String; let kind: Kind; var app = "" }

let modOrder = "⌃⌥⇧⌘"

// One line per shortcut: its modifiers, its key, what it does (macOS 26 defaults, U.S. layout).
// With `apps`, the text after the key is "<app>: <what it does>".
func parse(_ text: String, _ kind: Kind, apps: Bool = false) -> [Shortcut] {
    text.split(separator: "\n").map { line in
        let mods = line.prefix { modOrder.contains($0) }
        let rest = line.dropFirst(mods.count)
        let key = rest.prefix { $0 != " " }
        let said = String(rest.dropFirst(key.count + 1))
        let app = apps ? said.components(separatedBy: ": ")[0] : ""
        return Shortcut(mods: modOrder.filter(mods.contains), key: key.lowercased(),
                        label: apps ? String(said.dropFirst(app.count + 2)) : said, kind: kind, app: app)
    }
}

let shortcuts = parse(#"""
⌘Space Spotlight
⌥⌘Space Finder search
⌃Space Previous input source
⌃⌥Space Next input source
⌃⌘Space Emoji & Symbols
⌘Tab Switch app
⌘⇧Tab Switch app back
⌘` Next window of the app
⌘⇧` Previous window
⌘⇧3 Screenshot: screen
⌃⌘⇧3 Screen to clipboard
⌘⇧4 Screenshot: area
⌃⌘⇧4 Area to clipboard
⌘⇧5 Screenshot & record
⌃↑ Mission Control
⌃↓ App windows
⌃← Space left
⌃→ Space right
⌥⌘D Show/hide Dock
⌃⌘Q Lock screen
⌘⇧Q Log out
⌥⌘⇧Q Log out now
⌥⌘Esc Force Quit
⌃⌘D Look up word
⌘⇧/ Search the Help menu
⌃F1 Keyboard navigation
⌃F2 Focus menu bar
⌃F3 Focus Dock
⌃F4 Focus next window
⌃F5 Focus toolbar
⌃F6 Focus floating window
⌃F7 Tab moves focus
⌃F8 Focus status menus
⌘F5 VoiceOver
⌥⌘F5 Accessibility shortcuts
"""#, .macOS) + parse(#"""
⌘Q Quit
⌘W Close window
⌥⌘W Close all windows
⌘H Hide app
⌥⌘H Hide others
⌘M Minimize
⌥⌘M Minimize all
⌘, Settings
⌘N New
⌘O Open
⌘S Save
⌘⇧S Duplicate / Save As
⌘P Print
⌘⇧P Page setup
⌘Z Undo
⌘⇧Z Redo
⌘X Cut
⌘C Copy
⌘V Paste
⌥⌘⇧V Paste and match style
⌥⌘C Copy style
⌥⌘V Paste style
⌘A Select all
⌘F Find
⌘G Find next
⌘⇧G Find previous / Go to folder
⌘E Use selection for Find
⌘J Jump to selection
⌘B Bold
⌘I Italic / Get info
⌘U Underline
⌘T New tab / Fonts
⌘⇧T Reopen closed tab
⌘K Add link
⌘D Duplicate / Bookmark
⌘R Reload
⌘L Address bar
⌘Y History / Quick Look
⌘; Check spelling
⌘⇧; Spelling and grammar
⌘= Zoom in
⌘- Zoom out
⌘0 Actual size
⌘1 Tab 1 / View 1
⌘2 Tab 2 / View 2
⌘3 Tab 3 / View 3
⌘4 Tab 4 / View 4
⌘5 Tab 5
⌘6 Tab 6
⌘7 Tab 7
⌘8 Tab 8
⌘9 Last tab
⌘. Cancel
⌘[ Back
⌘] Forward
⌘⇧[ Previous tab
⌘⇧] Next tab
⌃⌘F Full screen
⌃Tab Next tab
⌃⇧Tab Previous tab
⌘⇧N New folder / private window
⌘⇧A Applications folder
⌘⇧D Desktop folder
⌘⇧H Home folder
⌘⇧O Documents folder
⌘⇧. Show hidden files
⌘⌫ Delete / to line start
"""#, .apps) + parse(#"""
⌃A Line start
⌃E Line end
⌃B Back one character
⌃F Forward one character
⌃P Previous line
⌃N Next line
⌃D Delete forward
⌃H Delete back
⌃K Cut to line end
⌃Y Paste what ⌃K cut
⌃O Insert line break after
⌃T Swap characters
⌃L Center the line
⌘← Line start
⌘→ Line end
⌘↑ Document start
⌘↓ Document end
⌥← Previous word
⌥→ Next word
⌥↑ Paragraph start
⌥↓ Paragraph end
⇧← Select left
⇧→ Select right
⇧↑ Select up
⇧↓ Select down
⌘⇧← Select to line start
⌘⇧→ Select to line end
⌘⇧↑ Select to start
⌘⇧↓ Select to end
⌥⇧← Select word left
⌥⇧→ Select word right
⌥⌫ Delete word
"""#, .text)

let byCombo = Dictionary(shortcuts.map { ($0.mods + $0.key, $0) }, uniquingKeysWith: { a, _ in a })

// What my apps register, read from their code (opener, alt-tab, screenshot, watcher, fleet) and my setup
// (my-setup/macos/hotkeys.md, the U.S. Accents layout, Ghostty's config). Fleet's panel chord and Handy's are read live.
let myGlobals = parse(#"""
⌘Space opener: Open an app
⌘E opener: Home folder in Finder
⌥⌘F opener: New Firefox window
⌥⌘T opener: New Ghostty window
⌥⌘J opener: New Vibe Code X window
⌥⌘O opener: One Text
⌘Tab alt-tab: Switch window
⇧⌘5 screenshot: Screenshot
⌥⌘K Watcher: Inbox
⌥⌘← Fleet: Window to the desktop on the left
⌥⌘→ Fleet: Window to the desktop on the right
⌥E U.S. Accents: é
⌥⇧E U.S. Accents: É
⌥A U.S. Accents: à
⌥⇧A U.S. Accents: À
⌥C U.S. Accents: ç
⌥⇧C U.S. Accents: Ç
"""#, .mine, apps: true)

let inMyApps = parse(#"""
⌘D One Text: Search people
⌘F One Text: Favorite under the pointer, or find
⌘K One Text: Mark as seen
⌘R One Text: Reply
⌘G One Text: Edit my message
⌘M One Text: Give an alias
⌘← One Text: Move the favorite
⌘→ One Text: Move the favorite
⌘↑ One Text: Move the favorite
⌘↓ One Text: Move the favorite
⌘, One Text: Settings
⌘Q Vibe Code X: Close the session
⇧⌘N Vibe Code X: New window
⌘O Vibe Code X: Open a project
⌘W Vibe Code X: Close the window
⌘F Vibe Code X: Find
⌘, Vibe Code X: Settings
⌘↑ Disk Map: Up a folder
Esc Fleet: Dismiss the panel
↩ Fleet: Send the prompt
⌘⌫ Fleet: Remove the card under the pointer
Esc screenshot: Cancel
↩ screenshot: Take it
⌥D screenshot: Flip the D setting
⌥L screenshot: Flip the L setting
⌥O screenshot: Flip the O setting
⌥C screenshot: Flip the C setting
⌥P screenshot: Flip the P setting
⌥M screenshot: Flip the M setting
⌥C Ghostty: Quit this Ghostty
"""#, .inMyApps, apps: true)

let usedOften = parse(#"""
⌥← Text: Previous word
⌥→ Text: Next word
⌥⌫ fish: Delete a kebab-case word
⌘L Firefox: Address bar
⌃Tab Firefox: Next tab
"""#, .often, apps: true)

// macOS key codes (U.S. layout) to this keyboard's key ids.
let keyCodes: [Int: String] = {
    var map: [Int: String] = [36: "↩", 48: "tab", 49: "space", 51: "⌫", 53: "esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
                              122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
                              109: "f10", 103: "f11", 111: "f12"]
    for (i, c) in "asdfhgzxcv_bqweryt123465=97-80]ou[ip_lj'k;\\,/nm.".enumerated() where c != "_" { map[i] = String(c) }
    map[50] = "`"
    return map
}()

func combo(_ mods: String, _ keyCode: Int) -> (String, String)? { keyCodes[keyCode].map { (mods, $0) } }

// NSEvent flags (symbolic hotkeys) or Carbon flags (RegisterEventHotKey); fn is left out.
func cocoaMods(_ f: Int) -> String {
    modOrder.filter { ["⌃": 1 << 18, "⌥": 1 << 19, "⇧": 1 << 17, "⌘": 1 << 20][$0]! & f != 0 }
}
func carbonMods(_ f: Int) -> String {
    modOrder.filter { ["⌃": 4096, "⌥": 2048, "⇧": 512, "⌘": 256][$0]! & f != 0 }
}

// System Settings → Keyboard Shortcuts, by id: the default chord ("-" when it has none) and name. An id missing
// from com.apple.symbolichotkeys keeps its default; one there says whether it is on and its chord.
let symbolic: [Int: (Shortcut?, String)] = Dictionary(uniqueKeysWithValues: #"""
7 ⌃F2 Focus menu bar
8 ⌃F3 Focus Dock
9 ⌃F4 Focus next window
10 ⌃F5 Focus toolbar
11 ⌃F6 Focus floating window
12 ⌃F1 Keyboard navigation
13 ⌃F7 Tab moves focus
27 ⌘` Next window of the app
28 ⇧⌘3 Screenshot: screen
29 ⌃⇧⌘3 Screen to clipboard
30 ⇧⌘4 Screenshot: area
31 ⌃⇧⌘4 Area to clipboard
32 ⌃↑ Mission Control
33 ⌃↓ App windows
34 - Mission Control (slow)
35 - App windows (slow)
36 F11 Show Desktop
37 - Show Desktop (slow)
52 ⌥⌘D Show/hide Dock
57 ⌃F8 Focus status menus
59 ⌘F5 VoiceOver
60 ⌃Space Previous input source
61 ⌃⌥Space Next input source
64 ⌘Space Spotlight
65 ⌥⌘Space Finder search
70 ⌃⌘D Look up word
79 ⌃← Space left
80 - Space left (slow)
81 ⌃→ Space right
82 - Space right (slow)
98 ⇧⌘/ Search the Help menu
162 ⌥⌘F5 Accessibility shortcuts
184 ⇧⌘5 Screenshot & record
"""#.split(separator: "\n").map { line in
    let parts = line.split(separator: " ", maxSplits: 1)
    let rest = String(parts[1])
    if rest.hasPrefix("- ") { return (Int(parts[0])!, (nil, String(rest.dropFirst(2)))) }
    let s = parse(rest, .macLive)[0]
    return (Int(parts[0])!, (s, s.label))
})

let macAlways = parse(#"""
⌘Tab macOS: Switch app
⌥⌘Esc macOS: Force Quit
⌃⌘Q macOS: Lock screen
⇧⌘Q macOS: Log out
⌥⇧⌘Q macOS: Log out now
⌃⌘Space macOS: Emoji & Symbols
"""#, .macLive, apps: true)

func macOnThisMac(_ saved: [String: Any]) -> [Shortcut] {
    let ids = Set(symbolic.keys).union(saved.keys.compactMap { Int($0) })
    return macAlways + ids.sorted().compactMap { id in
        let name = symbolic[id]?.1 ?? "System shortcut \(id)"
        guard let entry = saved[String(id)] as? [String: Any] else {
            return symbolic[id]?.0.map { Shortcut(mods: $0.mods, key: $0.key, label: name, kind: .macLive, app: "macOS") }
        }
        let p = (entry["value"] as? [String: Any])?["parameters"] as? [Int] ?? []
        guard (entry["enabled"] as? Bool) == true, p.count == 3, let (m, key) = combo(cocoaMods(p[2]), p[1]) else { return nil }
        return Shortcut(mods: m, key: key, label: name, kind: .macLive, app: "macOS")
    }
}

// Fleet stores its panel chord as "<Carbon key code>:<Carbon modifiers>"; ⌥⌘L until one is picked.
func fleetPanel(_ stored: String?) -> Shortcut? {
    let parts = (stored ?? "37:2304").split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, let (m, key) = combo(carbonMods(parts[1]), parts[0]) else { return nil }
    return Shortcut(mods: m, key: key, label: "Panel", kind: .mine, app: "Fleet")
}

// Handy keeps each binding as "command_left+s" or "option+shift+space".
func handyChord(_ binding: String, _ label: String) -> Shortcut? {
    var mods = "", key: String?
    for part in binding.lowercased().split(separator: "+") {
        let word = part.split(separator: "_")[0]
        switch word {
        case "command", "cmd", "super", "meta": mods += "⌘"
        case "option", "alt": mods += "⌥"
        case "shift": mods += "⇧"
        case "control", "ctrl": mods += "⌃"
        case "escape": key = "esc"
        default: key = String(word)
        }
    }
    guard let key, rows.joined().contains(where: { $0.id == key }) else { return nil }
    return Shortcut(mods: modOrder.filter(mods.contains), key: key, label: label, kind: .mine, app: "Handy")
}

func readMine() -> [Shortcut] {
    let saved = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
    let panel = CFPreferencesCopyAppValue("panelChord" as CFString, "com.mr.fleet" as CFString) as? String
    let handyFile = NSHomeDirectory() + "/Library/Application Support/com.pais.handy/settings_store.json"
    let bindings = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: handyFile)))) as? [String: Any])
        .flatMap { ($0["settings"] as? [String: Any])?["bindings"] as? [String: Any] } ?? [:]
    let handy = [("transcribe", "Dictation"), ("transcribe_with_post_process", "Dictation, cleaned up")].compactMap { id, label in
        ((bindings[id] as? [String: Any])?["current_binding"] as? String).flatMap { handyChord($0, label) }
    }
    return myGlobals + [fleetPanel(panel)].compactMap { $0 } + handy + macOnThisMac(saved as? [String: Any] ?? [:])
        + inMyApps + usedOften
}

struct Key { let id: String; let cap: String; let width: CGFloat }
func k(_ id: String, _ width: CGFloat = 1, _ cap: String? = nil) -> Key { Key(id: id, cap: cap ?? id.uppercased(), width: width) }
func keys(_ s: String) -> [Key] { s.map { k(String($0)) } }

let rows: [[Key]] = [
    [k("esc", 1.5, "esc")] + (1...12).map { k("f\($0)", 1.125) },
    keys("`1234567890-=") + [k("⌫", 2, "delete")],
    [k("tab", 1.5, "tab")] + keys("qwertyuiop[]") + [k("\\", 1.5)],
    [k("caps", 1.75, "caps lock")] + keys("asdfghjkl;'") + [k("↩", 2.25, "return")],
    [k("⇧", 2.25, "shift")] + keys("zxcvbnm,./") + [k("⇧", 2.75, "shift")],
    [k("fn", 1, "fn"), k("⌃", 1, "control"), k("⌥", 1, "option"), k("⌘", 1.25, "command"), k("space", 5.5, ""),
     k("⌘", 1.25, "command"), k("⌥", 1, "option"), k("←"), k("↑↓"), k("→")],
]

final class Mods: ObservableObject {
    @Published var clicked = ""
    @Published var held = ""
    var shown: String { held.isEmpty ? clicked : held }
    func toggle(_ m: Character) { clicked = modOrder.filter { ($0 == m) != clicked.contains($0) } }
    @Published var hidden = Set((UserDefaults.standard.stringArray(forKey: "hidden") ?? []).compactMap(Kind.init)) {
        didSet { UserDefaults.standard.set(hidden.map(\.rawValue), forKey: "hidden") }
    }
    // Shortcuts he gives up: shown struck out and counted as free. Until he picks, the menu items few people use.
    @Published var freed = Set(UserDefaults.standard.stringArray(forKey: "freed") ?? rarelyUsed) {
        didSet { UserDefaults.standard.set(Array(freed), forKey: "freed") }
    }
    @Published var tab = UserDefaults.standard.integer(forKey: "tab") {
        didSet { UserDefaults.standard.set(tab, forKey: "tab") }
    }
    @Published var search = ""
    var mine = readMine()

    var kinds: [Kind] { tab == 0 ? Kind.mineTab : Kind.defaultsTab }
    // A search shows every match, hidden colours included: looking for an app means wanting all of it.
    var visible: [Shortcut] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return (tab == 0 ? mine : shortcuts).filter { s in
            q.isEmpty ? !hidden.contains(s.kind) : "\(s.app) \(s.label)".lowercased().contains(q)
        }
    }
    func free(_ s: Shortcut) -> Bool { tab == 1 && freed.contains(s.mods + s.key) }
}

let rarelyUsed = ["⌘e", "⌘j", "⌘;", "⇧⌘;", "⌥⌘c", "⌥⌘v", "⌥⌘m", "⇧⌘a", "⇧⌘d", "⇧⌘h", "⇧⌘o"]

struct Keyboard: View {
    @ObservedObject var mods: Mods
    let unit: CGFloat = 70, gap: CGFloat = 5

    var body: some View {
        let visible = mods.visible
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Picker("", selection: $mods.tab) {
                    Text("Mine").tag(0)
                    Text("macOS defaults").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField("Search an app or an action", text: $mods.search)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
                Spacer()
            }
            HStack(spacing: 18) {
                Text(mods.shown.isEmpty ? "Hold or click ⌃ ⌥ ⇧ ⌘" : "\(mods.shown) + key")
                    .font(.title2.weight(.semibold))
                Spacer()
                ForEach(mods.kinds, id: \.self) { kind in
                    let on = !mods.hidden.contains(kind)
                    Button { mods.hidden.formSymmetricDifference([kind]) } label: {
                        Label { Text(kind.rawValue).strikethrough(!on) } icon: {
                            RoundedRectangle(cornerRadius: 3).fill(kind.color).frame(width: 12, height: 12)
                        }
                    }
                    .buttonStyle(.plain)
                    .opacity(on ? 1 : 0.35)
                    .help(on ? "Hide these shortcuts" : "Show these shortcuts")
                }
            }
            VStack(alignment: .leading, spacing: gap) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(rows[r].indices, id: \.self) { i in cap(rows[r][i], visible, height: r == 0 ? 36 : unit) }
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: mods.shown)
            .animation(.easeOut(duration: 0.2), value: mods.hidden)
            .animation(.easeOut(duration: 0.2), value: mods.freed)
            .animation(.easeOut(duration: 0.2), value: mods.tab)
            .animation(.easeOut(duration: 0.2), value: mods.search)
            if mods.tab == 0 { list(visible) }
            Text(mods.tab == 0
                 ? "Fleet's panel chord, Handy's and the macOS ones are read from this Mac's settings at launch. "
                   + "With no modifier held, each key shows how many of its combinations are taken."
                 : "Click a shortcut to strike it out and count it as free; click again to take it back. "
                   + "With no modifier held, each key shows how many of its combinations are taken.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // Without a search, the globals only: the apps' own shortcuts would fill the window.
    func list(_ visible: [Shortcut]) -> some View {
        let shown = mods.search.isEmpty ? visible.filter { $0.kind == .mine || $0.kind == .macLive } : visible
        return VStack(alignment: .leading, spacing: 6) {
            Text(mods.search.isEmpty ? "Global, \(shown.count)" : "Matching \"\(mods.search)\", \(shown.count)")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(s.kind.color).frame(width: 8, height: 8)
                        Text(s.mods + (["space": "Space", "esc": "Esc", "tab": "Tab"][s.key] ?? s.key.uppercased()))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 64, alignment: .leading)
                        Text(s.app).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(s.label).font(.system(size: 11)).lineLimit(1)
                    }
                }
            }
        }
        .frame(width: 15 * unit + 14 * gap, alignment: .leading)
    }

    @ViewBuilder func cap(_ key: Key, _ visible: [Shortcut], height: CGFloat) -> some View {
        let width = key.width * unit + (key.width - 1) * gap
        if key.id == "↑↓" {
            VStack(spacing: 2) {
                AnyView(cap(k("↑"), visible, height: (height - 2) / 2))
                AnyView(cap(k("↓"), visible, height: (height - 2) / 2))
            }.frame(width: width)
        } else if modOrder.contains(key.id) {
            let on = mods.shown.contains(key.id)
            face(key.cap, nil, fill: on ? Color.accentColor : .clear, stroke: .secondary, bold: on)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .onTapGesture { mods.toggle(Character(key.id)) }
        } else {
            let combo = mods.shown + key.id
            let hits = visible.filter { $0.mods == mods.shown && $0.key == key.id }
            let hit = hits.first
            let free = hit.map(mods.free) ?? false
            let count = mods.shown.isEmpty ? visible.filter { $0.key == key.id && !mods.free($0) }.count : 0
            let note = hit.map { ($0.app.isEmpty ? "" : "\($0.app): ") + $0.label + (hits.count > 1 ? " +\(hits.count - 1)" : "") }
            face(key.cap, note ?? (count > 0 ? "\(count) taken" : nil),
                 fill: hit.map { free ? .clear : $0.kind.color.opacity(0.22) } ?? .clear,
                 stroke: hit.map { free ? .secondary : $0.kind.color } ?? .secondary, bold: false, struck: free)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .onTapGesture { if hit != nil && mods.tab == 1 { mods.freed.formSymmetricDifference([combo]) } }
                .help(hits.map { "\(mods.shown)\(key.cap): \($0.app.isEmpty ? "" : "\($0.app), ")\($0.label) (\($0.kind.rawValue))" }
                    .joined(separator: "\n") + (hit != nil && mods.tab == 1 ? "\nClick: " + (free ? "take it back" : "count it as free") : ""))
        }
    }

    func face(_ cap: String, _ note: String?, fill: Color, stroke: Color, bold: Bool, struck: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(stroke.opacity(0.6)))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cap).font(.system(size: 12, weight: bold ? .bold : .medium))
                    if let note {
                        Text(note).font(.system(size: 10)).strikethrough(struck).lineLimit(3).minimumScaleFactor(0.8)
                            .foregroundStyle(fill == .clear ? .secondary : .primary)
                    }
                }.padding(5)
            }
    }
}

struct KeymapApp: App {
    @StateObject private var mods = Mods()

    var body: some Scene {
        Window("Keymap", id: "main") {
            Keyboard(mods: mods).onAppear {
                NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    let f = event.modifierFlags
                    mods.held = String([(f.contains(.control), "⌃"), (f.contains(.option), "⌥"), (f.contains(.shift), "⇧"),
                                        (f.contains(.command), "⌘")].filter(\.0).map(\.1))
                    return event
                }
            }
        }
        .windowResizability(.contentSize)
    }
}

let args = CommandLine.arguments
if args.contains("--selftest") {
    let ids = Set(rows.joined().map(\.id) + ["↑", "↓"])
    for s in shortcuts { precondition(ids.contains(s.key) && !s.label.isEmpty, "bad line: \(s.mods)\(s.key) \(s.label)") }
    let combos = shortcuts.map { $0.mods + $0.key }
    precondition(Set(combos).count == combos.count, "a combination is listed twice")
    precondition(byCombo["⇧⌘3"]?.label == "Screenshot: screen" && byCombo["⌥⇧⌘v"]?.kind == .apps)
    precondition(rarelyUsed.allSatisfy { byCombo[$0]?.kind == .apps }, "rarelyUsed names a combination not in the menus list")
    for s in myGlobals + inMyApps + usedOften + macAlways + symbolic.values.compactMap(\.0) {
        precondition(ids.contains(s.key) && !s.label.isEmpty && (s.kind == .macLive || !s.app.isEmpty), "bad line: \(s.mods)\(s.key) \(s.label)")
    }
    precondition(keyCodes[14] == "e" && keyCodes[42] == "\\" && keyCodes[47] == "." && keyCodes[36] == "↩" && keyCodes[18] == "1")
    let saved: [String: Any] = ["64": ["enabled": false], "36": ["enabled": true, "value": ["parameters": [65535, 103, 8388608]]],
                                "65": ["enabled": true, "value": ["parameters": [101, 14, 1048576]]], "999": ["enabled": true, "value": ["parameters": [97, 0, 1310720]]]]
    let mac = macOnThisMac(saved).map { "\($0.mods)\($0.key) \($0.label)" }
    precondition(!mac.contains("⌘space Spotlight") && mac.contains("f11 Show Desktop") && mac.contains("⌘e Finder search")
                 && mac.contains("⌃⌘a System shortcut 999") && mac.contains("⌃⌘d Look up word"), "\(mac)")
    precondition(fleetPanel(nil).map { $0.mods + $0.key } == "⌥⌘l" && fleetPanel("49:6144").map { $0.mods + $0.key } == "⌃⌥space")
    precondition(handyChord("command_left+s", "x").map { $0.mods + $0.key } == "⌘s"
                 && handyChord("option+shift+space", "x").map { $0.mods + $0.key } == "⌥⇧space")
    let m = Mods(); m.toggle("⌘"); m.toggle("⇧"); m.toggle("⌘")
    precondition(m.shown == "⇧")
    m.search = "one text"  // tab is his saved choice: not written from here
    precondition(m.visible.allSatisfy { $0.app == "One Text" || $0.label.lowercased().contains("one text") })
    precondition(m.tab != 0 || m.visible.count == 12)  // its 11, and opener's ⌥⌘O
    print("selftest ok: \(shortcuts.count) defaults, \(m.mine.count) mine")
    exit(0)
}
if let i = args.firstIndex(of: "--render"), args.count > i + 1 {
    MainActor.assumeIsolated {
        // --render <png> [modifiers] [--tab 0|1] [--search <text>]
        func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } }
        let mods = Mods()
        mods.clicked = args.count > i + 2 && !args[i + 2].hasPrefix("--") ? args[i + 2] : ""
        if let tab = option("--tab").flatMap(Int.init) { mods.tab = tab }
        mods.search = option("--search") ?? ""
        // ImageRenderer leaves the picker and the search field out: host the view in a window never ordered front.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Keyboard(mods: mods))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
    }
    exit(0)
}
KeymapApp.main()

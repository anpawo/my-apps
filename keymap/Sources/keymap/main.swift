import AppKit
import SwiftUI

enum Kind: String, CaseIterable {
    case macOS = "macOS, in every app", apps = "Most apps' menus", text = "Text fields"
    var color: Color { switch self { case .macOS: .red; case .apps: .orange; case .text: .blue } }
}

struct Shortcut { let mods: String; let key: String; let label: String; let kind: Kind }

let modOrder = "⌃⌥⇧⌘"

// One line per shortcut: its modifiers, its key, what it does (macOS 26 defaults, U.S. layout).
func parse(_ text: String, _ kind: Kind) -> [Shortcut] {
    text.split(separator: "\n").map { line in
        let mods = line.prefix { modOrder.contains($0) }
        let rest = line.dropFirst(mods.count)
        let key = rest.prefix { $0 != " " }
        return Shortcut(mods: modOrder.filter(mods.contains), key: key.lowercased(),
                        label: String(rest.dropFirst(key.count + 1)), kind: kind)
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
    func live(_ s: Shortcut) -> Bool { !hidden.contains(s.kind) && !freed.contains(s.mods + s.key) }
}

let rarelyUsed = ["⌘e", "⌘j", "⌘;", "⇧⌘;", "⌥⌘c", "⌥⌘v", "⌥⌘m", "⇧⌘a", "⇧⌘d", "⇧⌘h", "⇧⌘o"]

struct Keyboard: View {
    @ObservedObject var mods: Mods
    let unit: CGFloat = 70, gap: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                Text(mods.shown.isEmpty ? "Hold or click ⌃ ⌥ ⇧ ⌘" : "\(mods.shown) + key")
                    .font(.title2.weight(.semibold))
                Spacer()
                ForEach(Kind.allCases, id: \.self) { kind in
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
                        ForEach(rows[r].indices, id: \.self) { i in cap(rows[r][i], height: r == 0 ? 36 : unit) }
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: mods.shown)
            .animation(.easeOut(duration: 0.2), value: mods.hidden)
            .animation(.easeOut(duration: 0.2), value: mods.freed)
            Text("Click a shortcut to strike it out and count it as free; click again to take it back. "
                 + "With no modifier held, each key shows how many of its combinations are taken.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder func cap(_ key: Key, height: CGFloat) -> some View {
        let width = key.width * unit + (key.width - 1) * gap
        if key.id == "↑↓" {
            VStack(spacing: 2) {
                AnyView(cap(k("↑"), height: (height - 2) / 2))
                AnyView(cap(k("↓"), height: (height - 2) / 2))
            }.frame(width: width)
        } else if modOrder.contains(key.id) {
            let on = mods.shown.contains(key.id)
            face(key.cap, nil, fill: on ? Color.accentColor : .clear, stroke: .secondary, bold: on)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .onTapGesture { mods.toggle(Character(key.id)) }
        } else {
            let combo = mods.shown + key.id
            let hit = byCombo[combo].flatMap { mods.hidden.contains($0.kind) ? nil : $0 }
            let free = mods.freed.contains(combo)
            let count = mods.shown.isEmpty ? shortcuts.filter { $0.key == key.id && mods.live($0) }.count : 0
            face(key.cap, hit?.label ?? (count > 0 ? "\(count) taken" : nil),
                 fill: hit.map { free ? .clear : $0.kind.color.opacity(0.22) } ?? .clear,
                 stroke: hit.map { free ? .secondary : $0.kind.color } ?? .secondary, bold: false, struck: free)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .onTapGesture { if hit != nil { mods.freed.formSymmetricDifference([combo]) } }
                .help(hit.map { "\(mods.shown)\(key.cap): \($0.label) (\($0.kind.rawValue)). Click: "
                    + (free ? "take it back" : "count it as free") } ?? "")
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
    let m = Mods(); m.toggle("⌘"); m.toggle("⇧"); m.toggle("⌘")
    precondition(m.shown == "⇧")
    print("selftest ok: \(shortcuts.count) shortcuts")
    exit(0)
}
if let i = args.firstIndex(of: "--render"), args.count > i + 1 {
    MainActor.assumeIsolated {
        let mods = Mods(); mods.clicked = args.count > i + 2 ? args[i + 2] : ""
        let renderer = ImageRenderer(content: Keyboard(mods: mods)); renderer.scale = 2
        try! renderer.nsImage!.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }!
            .write(to: URL(fileURLWithPath: args[i + 1]))
    }
    exit(0)
}
KeymapApp.main()

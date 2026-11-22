import AppKit
import Carbon.HIToolbox
import DesksCore

let usage = """
desks query                  the desktops of the menu bar's screen, as JSON
desks focus <n|next|prev>    go there at once, no slide
desks send <n|next|prev>     the window in front goes there (past the last: a new desktop)
desks carry <n|next|prev>    send, then follow it
desks new                    a new desktop
desks move <window id> <n>   that window goes to desktop n, nothing comes forward
desks --agent                the hotkeys: ⌃⌥1…9 focus, ⌃⌥⇧1…9 carry, ⌃⌥← ⌃⌥→ previous, next
"""

func run(_ arguments: [String]) -> Int32 {
    guard let verb = arguments.first else { print(usage); return 2 }
    let target = arguments.dropFirst().first.flatMap(Target.init)
    switch (verb, target) {
    case ("query", _):
        let rows = Spaces.desktops().enumerated().map { index, desktop in
            "{\"index\":\(index + 1),\"id\":\(desktop.id),\"fullscreen\":\(desktop.type == 4),\"current\":\(desktop.current)}"
        }
        print("[" + rows.joined(separator: ",") + "]")
        return 0
    case ("focus", let target?): return Spaces.focus(target) ? 0 : 1
    case ("send", let target?): return Spaces.sendFrontWindow(to: target, follow: false) ? 0 : 1
    case ("carry", let target?): return Spaces.sendFrontWindow(to: target, follow: true) ? 0 : 1
    case ("new", _): return Spaces.addDesktop() ? 0 : 1
    case ("move", _):
        guard arguments.count == 3, let window = CGWindowID(arguments[1]), let n = Int(arguments[2]), n >= 1,
              let space = Spaces.desktops().dropFirst(n - 1).first else { print(usage); return 2 }
        return Spaces.move(window, to: space.id) ? 0 : 1
    case ("--agent", _): Agent.run(); return 0
    default: print(usage); return 2
    }
}

/// The hotkeys, held by a background app so the Accessibility grant is its own. ⌃⌥, not macOS's ⌃:
/// his Spaces shortcuts are off so editors keep ⌃← ⌃→ (my-setup/macos/hotkeys.md).
enum Agent {
    private static var actions: [UInt32: () -> Void] = [:]
    private static let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)

        for (n, key) in digitKeys.enumerated() {
            bind(key, controlKey | optionKey) { Spaces.focus(.number(n + 1)) }
            bind(key, controlKey | optionKey | shiftKey) { Spaces.sendFrontWindow(to: .number(n + 1), follow: true) }
        }
        bind(kVK_LeftArrow, controlKey | optionKey) { Spaces.focus(.previous) }
        bind(kVK_RightArrow, controlKey | optionKey) { Spaces.focus(.next) }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Agent.actions[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
        app.run()
    }

    private static func bind(_ key: Int, _ modifiers: Int, _ action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers),
                                         EventHotKeyID(signature: OSType(0x6465736B), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { actions[id] = action } else {
            FileHandle.standardError.write("desks: hotkey \(key)/\(modifiers) taken (\(status))\n".data(using: .utf8)!)
        }
    }
}

exit(run(Array(CommandLine.arguments.dropFirst())))

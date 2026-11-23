import AppKit
import DesksCore

let usage = """
desks query                  the desktops of the menu bar's screen, as JSON
desks focus <n|next|prev>    go there at once, no slide
desks send <n|next|prev>     the window in front goes there (past the last: a new desktop)
desks carry <n|next|prev>    send, then follow it
desks new                    a new desktop
desks move <window id> <n>   that window goes to desktop n, nothing comes forward
desks launch <n> <app> [file...]  a test copy of the app (its own settings) opens on desktop n,
                             in the background; prints its window id
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
    case ("launch", _):
        guard arguments.count >= 3, let n = Int(arguments[1]), n >= 1,
              let space = Spaces.desktops().dropFirst(n - 1).first else { print(usage); return 2 }
        let files = arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }
        return Launch.test(URL(fileURLWithPath: arguments[2]), files: files, on: space.id) ? 0 : 1
    default: print(usage); return 2
    }
}

exit(run(Array(CommandLine.arguments.dropFirst())))

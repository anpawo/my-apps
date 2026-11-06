import Foundation
import UserNotifications

// mac-guard's banner, under its own name and shield: `osascript display notification` posts as Script Editor.
// `mac-guard.app/Contents/MacOS/mac-guard <text>` posts it and exits 0 once macOS has it, 1 if banners are refused.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: mac-guard <text>\n".utf8))
    exit(64)
}
let center = UNUserNotificationCenter.current()
let done = DispatchSemaphore(value: 0)
var posted = false
center.requestAuthorization(options: [.alert]) { granted, error in
    if let error { FileHandle.standardError.write(Data("mac-guard: \(error)\n".utf8)) }
    guard granted else { done.signal(); return }
    let content = UNMutableNotificationContent()
    content.title = "mac-guard"
    content.body = CommandLine.arguments[1]
    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
        posted = error == nil
        done.signal()
    }
}
// The first run waits on his answer to macOS's "allow notifications?".
_ = done.wait(timeout: .now() + 120)
exit(posted ? 0 : 1)

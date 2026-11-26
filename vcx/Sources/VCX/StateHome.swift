import Foundation

enum StateHome {
    static var current: String { NSHomeDirectory() + "/.local/state/vcx" }

    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["VCX_STATE_HOME"] ?? current, isDirectory: true)
    }
}

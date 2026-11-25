import Foundation
import SQLite3

@MainActor
enum TraceSafetyCheck {
    private static let contentionDelay: UInt64 = 200_000_000

    static func run(directory: URL, check: (Bool, String) -> Void) async {
        await contention(directory.appendingPathComponent("contention"), check: check)
        await invalidDatabases(directory, check: check)
        await databaseSymlink(directory, check: check)
    }

    private static func drained(_ directory: URL) async -> Bool {
        do { try await Trace.drain(directory); return true }
        catch { return false }
    }

    private static func contention(_ directory: URL, check: (Bool, String) -> Void) async {
        Trace.write(directory, "initial", [:])
        guard await drained(directory) else { check(false, "Trace fixture initializes its identified database"); return }
        var connection: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("conversations.sqlite").path, &connection) == SQLITE_OK,
              sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(connection); check(false, "Trace contention fixture holds a writer transaction"); return
        }
        Trace.write(directory, "contended", [:])
        let release = Task.detached {
            try? await Task.sleep(nanoseconds: contentionDelay)
            sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
            sqlite3_close(connection)
        }
        let saved = await drained(directory)
        await release.value
        check(saved && Trace.latest(directory)?["type"] as? String == "contended", "Trace waits for a competing writer and saves the queued event")
    }

    private static func invalidDatabases(_ root: URL, check: (Bool, String) -> Void) async {
        for corrupt in [true, false] {
            let directory = root.appendingPathComponent(corrupt ? "corrupt" : "foreign")
            let file = directory.appendingPathComponent("conversations.sqlite")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if corrupt { try Data("synthetic corrupt database".utf8).write(to: file) }
                else {
                    var connection: OpaquePointer?
                    guard sqlite3_open(file.path, &connection) == SQLITE_OK else { throw CXError(message: "Fixture database open failed") }
                    sqlite3_exec(connection, "CREATE TABLE foreign_data(value TEXT)", nil, nil, nil)
                    sqlite3_close(connection)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let before = try Data(contentsOf: file)
                Trace.write(directory, "refused", [:])
                let saved = await drained(directory)
                let unchanged = try Data(contentsOf: file) == before
                check(!saved && unchanged, "Trace preserves invalid database bytes and reports a blocked drain")
            } catch { check(false, "Trace invalid database fixture completes") }
        }
    }

    private static func databaseSymlink(_ root: URL, check: (Bool, String) -> Void) async {
        let directory = root.appendingPathComponent("symlink"), target = root.appendingPathComponent("foreign/conversations.sqlite")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let before = try Data(contentsOf: target)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("conversations.sqlite"), withDestinationURL: target)
            Trace.write(directory, "refused", [:])
            let saved = await drained(directory)
            let unchanged = try Data(contentsOf: target) == before
            check(!saved && unchanged, "Trace refuses a database symlink without changing its target")
        } catch { check(false, "Trace symlink fixture completes") }
    }
}

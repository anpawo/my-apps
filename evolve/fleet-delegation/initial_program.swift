import Foundation

// EVOLVE-BLOCK-START
// Fleet TranscriptStore cold read: before parsing the tail of a Claude transcript, the head of the file
// (often megabytes) is scanned for the few lines that start or end a background shell or an agent.
// Contract: return exactly the lines (split on "\n", empty lines dropped) that contain any mark, in file order.
// No global or static mutable state, no caches between calls, no threads.
enum Delegation {
    static let marks = ["background with ID", "moved to the background",
                        "Workflow launched in background", "<task-notification>",
                        "Successfully stopped task",
                        #""name":"Agent""#, #""name":"Task""#,
                        "Async agent launched", "resumedAgentId",
                        #""toolUseResult":{"status":"completed""#].map { Data($0.utf8) }

    static func lines(in head: Data) -> [Data] {
        head.split(separator: UInt8(ascii: "\n"))
            .filter { raw in marks.contains(where: { raw.range(of: $0) != nil }) }
            .map { Data($0) }
    }
}
// EVOLVE-BLOCK-END

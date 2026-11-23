import Foundation
let a = CommandLine.arguments
let data = try! Data(contentsOf: URL(fileURLWithPath: a[1]))
let reps = Int(a[2])!
// Extra cases: marks at the very start/end, empty lines, a mark split across a newline, no trailing newline.
let edge = Data("resumedAgentId x\n\n\nfoo <task-\nnotification> bar\n\"name\":\"Task\"\nzz background with ID".utf8)
var out = Data()
for d in [data, edge, Data(), Data("\n\n".utf8), data.prefix(12345)] {
    let r = Delegation.lines(in: Data(d))
    out.append(contentsOf: Array("\(r.count)\n".utf8))
    for l in r { out.append(l); out.append(0x0A) }
}
try! out.write(to: URL(fileURLWithPath: a[3]))
var best = UInt64.max, sink = 0
for _ in 0..<reps {
    let t = DispatchTime.now().uptimeNanoseconds
    sink &+= Delegation.lines(in: data).count
    best = min(best, DispatchTime.now().uptimeNanoseconds - t)
}
print(best, sink)

import Foundation
let a = CommandLine.arguments
let rules = try! String(contentsOfFile: a[1], encoding: .utf8).split(separator: "\n").map(String.init)
let prompts = try! String(contentsOfFile: a[2], encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
let reps = Int(a[3])!
var out = ""
for p in prompts { out += Recall.recall(p, texts: rules).joined(separator: "\u{1}") + "\n" }
for p in prompts.prefix(60) { out += Recall.recall(p, texts: rules, limit: 10, minimum: 1).joined(separator: "\u{1}") + "\n" }
try! out.write(toFile: a[4], atomically: true, encoding: .utf8)
var best = UInt64.max, sink = 0
for _ in 0..<reps {
    let t = DispatchTime.now().uptimeNanoseconds
    for p in prompts { sink &+= Recall.recall(p, texts: rules).count }
    best = min(best, DispatchTime.now().uptimeNanoseconds - t)
}
print(best, sink)

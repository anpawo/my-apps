import Foundation
import DesksCore

var failures = 0
func expect(_ name: String, _ actual: Int?, _ expected: Int?) {
    if actual == expected { print("ok    \(name)") } else {
        failures += 1
        print("FAIL  \(name): got \(String(describing: actual)), want \(String(describing: expected))")
    }
}

expect("goes to the numbered desktop", Target("3")!.index(from: 0, count: 4), 2)
expect("clamps a number past the last desktop to the last", Target("9")!.index(from: 0, count: 4), 3)
expect("stays put when the numbered desktop is the current one", Target("2")!.index(from: 1, count: 4), nil)
expect("next steps one to the right", Target("next")!.index(from: 1, count: 4), 2)
expect("next stops at the last desktop", Target("next")!.index(from: 3, count: 4), nil)
expect("prev stops at the first desktop", Target("prev")!.index(from: 0, count: 4), nil)
expect("rejects desktop zero", Target("0").map { _ in 1 }, nil)
expect("rejects a word that is not a target", Target("left").map { _ in 1 }, nil)

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")

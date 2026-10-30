import CoreGraphics
import Foundation
import ScreenshotCore

var failures = 0
func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

// A second display left of, and higher than, the 1000×800 main one.
let side = CGRect(x: -500, y: 200, width: 500, height: 400)
let sel = CGRect(x: -400, y: 500, width: 100, height: 50)
expect(displayLocal(sel, in: side) == CGRect(x: 100, y: 50, width: 100, height: 50),
       "selection on a secondary display flips into its own top-left frame")
expect(pixelCrop(sel, in: side, scale: 2) == CGRect(x: 200, y: 100, width: 200, height: 100),
       "pixel crop scales the local rect")
expect(appKit(CGRect(x: 10, y: 20, width: 30, height: 40), mainHeight: 800)
       == CGRect(x: 10, y: 740, width: 30, height: 40), "CG → AppKit flip")

expect(cardSize(CGSize(width: 1600, height: 1000), side: 147) == CGSize(width: 147, height: 92),
       "a wide capture's card fills the width")
expect(cardSize(CGSize(width: 294, height: 788), side: 147) == CGSize(width: 74, height: 92),
       "a tall capture's card is no taller than a wide one, and stays wide enough to click")

let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
let r = CGRect(x: 10, y: 10, width: 20, height: 20)
expect(nudge(r, dx: 5, dy: 0, resize: false, bounds: bounds).minX == 15, "move right")
expect(nudge(r, dx: 200, dy: 0, resize: false, bounds: bounds).maxX == 100, "move clamps to bounds")
expect(nudge(r, dx: 0, dy: 5, resize: true, bounds: bounds).height == 25, "resize grows")
expect(nudge(r, dx: 0, dy: -50, resize: true, bounds: bounds).height == 1, "resize never below 1")
expect(nudge(r, dx: 500, dy: 0, resize: true, bounds: bounds).maxX == 100, "resize clamps to bounds")
let far = r.offsetBy(dx: 20, dy: 0)
expect(glide(r, far, 0) == r && glide(r, far, 1) == far && glide(r, far, 2) == far, "glide starts at a, lands on b")
let xs = (0...20).map { glide(r, far, CGFloat($0) / 20).minX }
expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 } && xs[1] - xs[0] > xs[20] - xs[19], "glide moves one way, eased out")

expect(resized(r, handle: 4, to: CGPoint(x: 50, y: 60)) == CGRect(x: 10, y: 10, width: 40, height: 50),
       "top-right handle keeps the bottom-left corner")
expect(resized(r, handle: 0, to: CGPoint(x: 50, y: 50)) == CGRect(x: 30, y: 30, width: 20, height: 20),
       "dragging a corner past the opposite one flips cleanly")
expect(resized(r, handle: 3, to: CGPoint(x: 70, y: 0)) == CGRect(x: 10, y: 10, width: 60, height: 20),
       "an edge handle ignores the other axis")

let screen = [CGRect(x: 0, y: 0, width: 1470, height: 956)]
expect(pickable(layer: 0, frame: CGRect(x: 0, y: 0, width: 1470, height: 956), screens: screen), "a normal window, even full-screen")
expect(pickable(layer: 25, frame: CGRect(x: 435, y: 287, width: 600, height: 669), screens: screen), "Jarvis's panel")
expect(!pickable(layer: 24, frame: CGRect(x: 0, y: 923, width: 1470, height: 33), screens: screen), "not the menu bar")
expect(!pickable(layer: 25, frame: CGRect(x: 1341, y: 923, width: 131, height: 33), screens: screen), "not a menu bar icon")
expect(!pickable(layer: 3, frame: screen[0], screens: screen), "not a full-screen overlay (Fleet, Watcher)")
expect(!pickable(layer: -2147483601, frame: CGRect(x: 922, y: 725, width: 180, height: 180), screens: screen), "not a desktop widget")

var bar = BarState(target: .area, kind: .photo)
bar.step(1); expect(bar == BarState(target: .screen, kind: .video), "⌘→ goes from the last still to the first recording")
bar.step(-1); expect(bar == BarState(target: .area, kind: .photo), "⌘← comes back")
bar = BarState(target: .area, kind: .video)
bar.step(1); expect(bar == BarState(target: .screen, kind: .photo), "⌘→ wraps around")
bar.toggleKind(); expect(bar.kind == .video && bar.target == .screen, "⌘⇧5 keeps the target")
expect(BarState.all.count == 6, "six buttons, like the system")

let name = fileName(kind: "Screenshot", app: "Safari/Beta", ext: "png", at: Date(timeIntervalSince1970: 0))
expect(name.hasPrefix("Screenshot Safari-Beta 1970-01-01 at ") && name.hasSuffix(".png"), "file name: \(name)")

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let old = tmp.appendingPathComponent("Screenshot Zed 2020.png"), new = tmp.appendingPathComponent("Screenshot 2026.png")
for (u, d) in [(old, Date(timeIntervalSince1970: 0)), (new, Date())] {
    FileManager.default.createFile(atPath: u.path, contents: nil)
    try! FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: u.path)
}
expect(newestFirst([old, new]) == [new, old], "history is newest first by date, whatever the names")
try? FileManager.default.removeItem(at: tmp)
if failures > 0 { exit(1) }
print("ok")

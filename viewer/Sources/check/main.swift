import Foundation
import ViewerCore

var failures = 0
func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

expect(Speed.step(1, by: 1) == 1.25 && Speed.step(1, by: -1) == 0.75, "one step either way from 1×")
expect(Speed.step(4, by: 1) == 4 && Speed.step(0.25, by: -1) == 0.25, "speed clamps at both ends")
expect(Speed.step(1.1, by: 1) == 1.25, "an off-step speed snaps to the nearest step first")
expect(Speed.label(1.5) == "1.5×" && Speed.label(2) == "2×", "speed label")
expect(Volume.step(1, by: 1) == 1 && Volume.step(0, by: -1) == 0, "volume clamps to 0...1")
expect(Volume.label(Volume.step(0.5, by: 1)) == "Volume 60%", "volume steps by 10%")

expect(Kind(url: URL(fileURLWithPath: "/a.gif")) == .gif, "gif before image")
expect(Kind(url: URL(fileURLWithPath: "/a.PNG")) == .image, "png, any case")
expect(Kind(url: URL(fileURLWithPath: "/a.mp4")) == .video && Kind(url: URL(fileURLWithPath: "/a.mov")) == .video, "movies")
expect(Kind(url: URL(fileURLWithPath: "/a.pdf")) == .pdf, "pdf")
expect(Kind(url: URL(fileURLWithPath: "/a.txt")) == nil, "text is not media")

let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.mp4"), c = URL(fileURLWithPath: "/tmp/c.pdf")
var list = Playlist()
expect(list.current == nil, "empty list selects nothing")
list.add([a, b])
expect(list.items == [a, b] && list.current == a, "add selects the first new item")
list.add([URL(fileURLWithPath: "/tmp/./b.mp4"), c])
expect(list.items == [a, b, c] && list.current == b, "a file already listed is not added again, it is selected")
list.move(by: 1); list.move(by: 1)
expect(list.current == c, "next stops at the last item")
list.move(by: -5)
expect(list.current == a, "previous stops at the first item")
list.select(2); list.removeSelected()
expect(list.items == [a, b] && list.current == b, "removing the last item selects the one before")
list.select(0); list.removeSelected()
expect(list.items == [b] && list.current == b, "removing selects the item that took its place")
list.removeSelected()
expect(list.items.isEmpty && list.current == nil, "removing the only item empties the list")

let durations = [0.1, 0.2, 0.3]
expect(Timeline.frame(at: 0, durations: durations) == 0, "time 0 is the first frame")
expect(Timeline.frame(at: 0.15, durations: durations) == 1, "time falls inside the second frame")
expect(Timeline.frame(at: 9, durations: durations) == 2, "past the end is the last frame")
expect(abs(Timeline.start(of: 2, durations: durations) - 0.3) < 1e-9, "a frame starts after the ones before it")
expect(Timeline.delay(0) == 0.1 && Timeline.delay(nil) == 0.1 && Timeline.delay(0.04) == 0.04, "too short delays play as browsers do")

let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for name in ["b10.png", "b2.gif", "notes.txt", ".hidden.png"] {
    FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
}
expect(mediaFiles(in: [dir]).map(\.lastPathComponent) == ["b2.gif", "b10.png"],
       "a folder gives its visible media files in Finder order")
try? FileManager.default.removeItem(at: dir)

if failures > 0 { exit(1) }
print("ok")

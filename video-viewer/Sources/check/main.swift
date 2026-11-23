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

expect(Kind(url: URL(fileURLWithPath: "/a.mp3")) == .music && Kind(url: URL(fileURLWithPath: "/a.m4a")) == .music, "audio is music, not video")

expect(Details.duration(7) == "0:07" && Details.duration(65.4) == "1:05" && Details.duration(3723) == "1:02:03", "durations")
expect(Details.pages(1) == "1 page" && Details.pages(3) == "3 pages" && Details.items(2) == "2 items", "counts")
expect(Details.pixels(1920, 1080) == "1920 × 1080", "pixel size")

expect(Recent.adding("/c", to: ["/a", "/b"]) == ["/c", "/a", "/b"], "recent puts the newest file first")
expect(Recent.adding("/n", to: (1...Recent.kept).map { "/\($0)" }).count == Recent.kept, "recent keeps a bounded history")
expect(Recent.shown(["/d", "/c", "/a", "/b"], open: []) == ["/d", "/c", "/a"], "recent shows only the last three")
expect(Recent.shown(["/d", "/c", "/a", "/b"], open: ["/c"]) == ["/d", "/a", "/b"], "recent leaves out the files open in the window")
expect(Recent.adding("/a", to: ["/c", "/a", "/b"]) == ["/a", "/c", "/b"], "reopening a recent file moves it to the top")

func entry(_ name: String) -> Entry {
    let url = URL(fileURLWithPath: "/tmp/" + name)
    return Entry(url: url, kind: Kind(url: url)!, modified: Date())
}
let old = entry("old.png"), clip = entry("clip.mp4"), doc = entry("doc.pdf"), song = entry("song.mp3")
var library = Library()
expect(library.current == nil && library.shown.isEmpty, "an empty library shows nothing")
library.add([old, clip])
expect(library.shown == [old, clip] && library.current == old.url,
       "the list keeps the opening order and adding shows the first file passed")
library.add([entry("doc.pdf"), song, clip])
expect(library.shown.map(\.url) == [old, clip, doc, song].map(\.url) && library.current == doc.url, "a file already listed is not added again")
library.move(by: -1)
expect(library.current == clip.url, "up walks the list in its displayed order")
library.move(by: 9)
expect(library.current == song.url, "down stops at the last item")
library.filter(query: "CL")
expect(library.shown == [clip] && library.current == clip.url, "search keeps names containing the text, any case")
library.add([old])
expect(library.query.isEmpty && library.current == old.url, "adding a file the search hides clears the search")
library.select(clip.url)
library.removeCurrent()
expect(library.current == doc.url && library.entries.count == 3, "removing shows the item that took its place")
library.select(song.url)
library.removeCurrent()
expect(library.current == doc.url, "removing the last item shows the one before")
library.removeCurrent()
library.removeCurrent()
expect(library.entries.isEmpty && library.current == nil, "removing every item empties the list")

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

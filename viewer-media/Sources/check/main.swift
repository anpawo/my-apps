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

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T12:00:00Z")! }
let now = day("2026-11-22")
let titles = ["2026-11-22", "2026-11-21", "2026-11-17", "2026-10-30", "2026-10-20", "2026-02-01", "2025-12-31"]
    .map { DateGroup.title(for: day($0), now: now, calendar: calendar) }
expect(titles == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "October", "February", "2025"],
       "dates group like Notes: today, yesterday, 7 and 30 days, months of this year, older years")
expect(DateGroup.rowDate(day("2026-11-21"), now: now, calendar: calendar) == "Yesterday", "yesterday's row says Yesterday")
expect(DateGroup.rowDate(day("2026-11-18"), now: now, calendar: calendar) == "Wednesday", "a row of this week names its weekday")
expect(Details.duration(7) == "0:07" && Details.duration(65.4) == "1:05" && Details.duration(3723) == "1:02:03", "durations")
expect(Details.pages(1) == "1 page" && Details.pages(3) == "3 pages" && Details.items(2) == "2 items", "counts")
expect(Details.pixels(1920, 1080) == "1920 × 1080", "pixel size")

func entry(_ name: String, _ date: String) -> Entry {
    let url = URL(fileURLWithPath: "/tmp/" + name)
    return Entry(url: url, kind: Kind(url: url)!, modified: day(date))
}
let old = entry("old.png", "2026-01-05"), clip = entry("clip.mp4", "2026-11-22"), doc = entry("doc.pdf", "2026-11-20")
let song = entry("song.mp3", "2026-11-21")
var library = Library()
expect(library.current == nil && library.shown.isEmpty, "an empty library shows nothing")
library.add([old, clip])
expect(library.shown.map(\.url) == [clip.url, old.url] && library.current == old.url,
       "the list is newest first and adding shows the first file passed")
library.add([entry("doc.pdf", "2026-11-20"), song, clip])
expect(library.entries.count == 4 && library.current == doc.url, "a file already listed is not added again")
expect(library.sections(now: now, calendar: calendar).map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "January"],
       "the list is split into date sections")
library.move(by: -1)
expect(library.current == song.url, "up walks the list in its displayed order")
library.move(by: 9)
expect(library.current == old.url, "down stops at the last item")
library.filter(query: "CL")
expect(library.shown == [clip] && library.current == clip.url, "search keeps names containing the text, any case")
library.add([old])
expect(library.query.isEmpty && library.current == old.url, "adding a file the search hides clears the search")
library.filter(query: "")
library.select(song.url)
library.removeCurrent()
expect(library.current == doc.url && library.entries.count == 3, "removing shows the item that took its place")
library.select(old.url)
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

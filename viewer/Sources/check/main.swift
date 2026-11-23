import Foundation
import TextCore
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
expect(Kind(url: URL(fileURLWithPath: "/a.txt")) == .text && Kind(url: URL(fileURLWithPath: "/a.swift")) == .text, "text and code")
expect(Kind(url: URL(fileURLWithPath: "/a.rs")) == .text, "a code kind macOS has no type for")
expect(Kind(url: URL(fileURLWithPath: "/a.zip")) == nil, "an archive opens nowhere here")
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-ts-\(getpid())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let code = dir.appendingPathComponent("app.ts"), stream = dir.appendingPathComponent("clip.ts")
    try! Data("export const a = 1\n".utf8).write(to: code)
    var packets = Data(count: 376); packets[0] = 0x47; packets[188] = 0x47
    try! packets.write(to: stream)
    expect(Kind(url: code) == .text, "a TypeScript .ts is text")
    expect(Kind(url: stream) == .video, "an MPEG transport stream .ts is video")
    let bare = dir.appendingPathComponent("login-notes"), binary = dir.appendingPathComponent("tool")
    let unknown = dir.appendingPathComponent("notes.zzqx")
    try! Data("hello\n".utf8).write(to: bare)
    try! Data("hello\n".utf8).write(to: unknown)
    try! Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0]).write(to: binary)
    expect(Kind(url: bare) == .text, "an extensionless text file is text")
    expect(Kind(url: unknown) == .text, "a text file with an extension nothing declares is text")
    expect(Kind(url: binary) == nil, "an extensionless binary opens nowhere here")
    expect(mediaFiles(in: [bare]) == [bare], "an opened extensionless text file is loaded")
}

expect(Kind(url: URL(fileURLWithPath: "/a.mp3")) == .music && Kind(url: URL(fileURLWithPath: "/a.m4a")) == .music, "audio is music, not video")

expect(Details.duration(7) == "0:07" && Details.duration(65.4) == "1:05" && Details.duration(3723) == "1:02:03", "durations")
expect(Details.pages(1) == "1 page" && Details.pages(3) == "3 pages" && Details.items(2) == "2 items", "counts")
expect(Details.pixels(1920, 1080) == "1920 × 1080", "pixel size")


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
expect(mediaFiles(in: [dir]).map(\.lastPathComponent) == ["b2.gif", "b10.png", "notes.txt"],
       "a folder gives its visible files in Finder order")
try? FileManager.default.removeItem(at: dir)

// Text: highlighter, language detection, file encoding.
do {
    func kinds(_ text: String, _ lang: Language, covering needle: String) -> [TokenKind] {
        let r = (text as NSString).range(of: needle)
        return Highlighter(lang).tokens(in: text).filter { NSIntersectionRange($0.range, r).length > 0 }.map(\.kind)
    }

    /// The tokens spanning exactly `needle` (its first occurrence).
    func exact(_ text: String, _ lang: Language, _ needle: String) -> [Token] {
        let r = (text as NSString).range(of: needle)
        return Highlighter(lang).tokens(in: text).filter { $0.range == r }
    }

    let url = #"let url = "https://example.com" // the site"#
    expect(kinds(url, .swift, covering: "//example") == [.string], "a // inside a string is not a comment")
    expect(kinds(url, .swift, covering: "// the") == [.comment], "a // after the string is a comment")
    expect(kinds(#"print("return if")"#, .swift, covering: "return") == [.string], "a keyword inside a string is not colored")
    expect(kinds("let x = 42", .swift, covering: "let") == [.keyword], "a Swift keyword is colored")
    expect(kinds("letter = 1", .swift, covering: "let").isEmpty, "a keyword inside a word is not colored")
    expect(kinds("# for x in y\nx = 1", .python, covering: "for") == [.comment], "a keyword inside a comment is not a keyword")
    expect(kinds("s = 'a # b'", .python, covering: "#") == [.string], "a # inside a Python string is not a comment")
    expect(kinds("echo $#", .shell, covering: "#").isEmpty, "$# in shell is not a comment")
    expect(kinds("fn f<'a>(x: &'a str)", .rust, covering: "'a>").isEmpty, "a Rust lifetime is not a string")
    expect(kinds(#"{"name": "for"}"#, .json, covering: #""name""#) == [.key], "a JSON key is a key")
    expect(kinds(#"{"name": "for"}"#, .json, covering: #""for""#) == [.string], "a JSON value is a string")
    expect(kinds("server:\n  port: 8080", .yaml, covering: "port") == [.key], "a YAML key is a key")
    expect(exact("port: 8080", .yaml, "8080").map(\.kind) == [.number], "a YAML number value is a number")
    expect(exact("name: Ada Lovelace", .yaml, "Ada Lovelace").map(\.kind) == [.string], "a plain YAML value is a string")
    expect(kinds("[tool]\nname = \"x\"", .toml, covering: "name") == [.attribute], "a TOML key is a property name")
    expect(kinds("# Title\ntext", .markdown, covering: "Title") == [.heading], "a markdown heading")
    expect(kinds("```\n# not a heading\n```", .markdown, covering: "not") == [.codeBlock], "a fenced block is code")
    expect(exact("```swift\nlet x = 1\n```", .markdown, "let").map(\.kind) == [.keyword], "a fenced block takes its language's colors")
    expect(exact("```python\nreturn 1\n```", .markdown, "return").map(\.kind) == [.control], "a fence named by its language's name")
    expect(kinds("<a href=\"x\">", .markup, covering: "<a") == [.punctuation, .tag], "an HTML tag and its bracket")
    expect(kinds("SELECT id FROM t", .sql, covering: "FROM") == [.keyword], "SQL keywords ignore case")
    expect(Highlighter(.plain).tokens(in: "let x = 1 // c").isEmpty, "plain text has no colors")

    let swiftCode = "func load(from url: URL) {\n    if let data = try? Data(url) { return }\n    print(self.count)\n}"
    expect(exact(swiftCode, .swift, "if").map(\.kind) == [.control], "if is a control keyword")
    expect(exact(swiftCode, .swift, "return").map(\.kind) == [.control], "return is a control keyword")
    expect(exact(swiftCode, .swift, "let").map(\.kind) == [.keyword], "let is a declaration keyword, not control")
    expect(exact(swiftCode, .swift, "func").map(\.kind) == [.keyword], "func is a declaration keyword")
    expect(exact(swiftCode, .swift, "load").map(\.kind) == [.function], "the name after func is a function")
    expect(exact(swiftCode, .swift, "URL").map(\.kind) == [.type], "a capitalized name is a type")
    expect(exact(swiftCode, .swift, "print").map(\.kind) == [.call], "a Swift call is a call")
    expect(exact(swiftCode, .swift, "Data").map(\.kind) == [.call], "a Swift initializer call is a call, as in VS Code")
    expect(exact(swiftCode, .swift, "self").map(\.kind) == [.constant], "self is a language variable")
    expect(exact(swiftCode, .swift, "count").map(\.kind) == [.property], "a name after a dot is a property")
    expect(exact("static let shared = nil", .swift, "static").map(\.kind) == [.modifier], "static is a modifier")
    expect(exact("static let shared = nil", .swift, "nil").map(\.kind) == [.literal], "nil is a literal")
    expect(exact("@MainActor final class Box {}", .swift, "@MainActor").map(\.kind) == [.modifier], "a Swift attribute")
    expect(exact("@MainActor final class Box {}", .swift, "Box").map(\.kind) == [.type], "the name after class is a type")
    expect(exact(#"let s = "a\nb""#, .swift, "\\n").map(\.kind) == [.escape], "an escape inside a string")

    let pyCode = "@cached\nclass Cart(Base):\n    LIMIT = 10\n    def total(self):\n        return sum(self.items)\n"
    expect(exact(pyCode, .python, "@cached").map(\.kind) == [.function], "a Python decorator is a function")
    expect(exact(pyCode, .python, "Cart").map(\.kind) == [.type], "a Python class name is a type")
    expect(exact(pyCode, .python, "LIMIT").map(\.kind) == [.constant], "an ALL_CAPS name is a constant")
    expect(exact(pyCode, .python, "total").map(\.kind) == [.function], "the name after def is a function")
    expect(exact(pyCode, .python, "sum").map(\.kind) == [.function], "a Python call is a function")
    expect(exact(pyCode, .python, "def").map(\.kind) == [.keyword], "def is a declaration keyword")
    expect(exact(pyCode, .python, "return").map(\.kind) == [.control], "return is a control keyword in Python too")

    let doc = "def area(r):\n    \"\"\"Area of a disc.\n\n    Args:\n        r (float): the radius.\n    \"\"\"\n    s = \"\"\"x\"\"\"\n"
    expect(kinds(doc, .python, covering: "Area of") == [.docstring], "a string standing alone after def is a docstring")
    expect(exact(doc, .python, "Args").map(\.kind) == [.escape], "a docstring section heading")
    expect(exact(doc, .python, " (float):").map(\.kind) == [.punctuation],
           "a docstring parameter's type")
    expect(exact(doc, .python, "x\"\"\"").isEmpty && kinds(doc, .python, covering: "x\"\"\"") == [.string],
           "an assigned triple-quoted string is a string, not a docstring")
    expect(Highlighter(.python).tokens(in: doc).contains { $0.kind == .variable && (doc as NSString).substring(with: $0.range) == "r" },
           "a docstring parameter name is a variable")

    let csv = "id,name,price\n1,\"Pen, blue\",2.5\n"
    let columns = Highlighter(.csv).tokens(in: csv)
    expect(exact(csv, .csv, "name,").map(\.index) == [1], "a CSV field holds its column")
    expect(exact(csv, .csv, "2.5").map(\.index) == [2], "a comma inside quotes does not start a column")
    expect(columns.allSatisfy { $0.kind == .column }, "CSV tokens are columns")
    expect(exact("a\tb\tc", .tsv, "c").map(\.index) == [2], "a TSV field holds its column")
    expect(exact("f(a[0])", .javascript, "[").map(\.index) == [1], "a bracket holds its nesting depth")
    expect(exact("f(\"(\")", .javascript, ")").map(\.index) == [0], "a bracket inside a string is not counted")

    expect(Language.detect(fileName: "main.swift", firstLine: nil) == .swift, "extension: swift")
    expect(Language.detect(fileName: "App.TSX", firstLine: nil) == .javascript, "extension: case-insensitive tsx")
    expect(Language.detect(fileName: "build.gradle.kts", firstLine: nil) == .java, "extension: kts")
    expect(Language.detect(fileName: "notes.txt", firstLine: "#!/bin/sh") == .plain, "txt stays plain")
    expect(Language.detect(fileName: "deploy", firstLine: "#!/usr/bin/env python3") == .python, "shebang through env")
    expect(Language.detect(fileName: "run", firstLine: "#!/usr/bin/env -S node --trace") == .javascript, "shebang env -S")
    expect(Language.detect(fileName: "go", firstLine: "#!/bin/bash -e") == .shell, "shebang with a flag")
    expect(Language.detect(fileName: "tool", firstLine: "#!/opt/bin/python3.12") == .python, "versioned interpreter")
    expect(Language.detect(fileName: "README", firstLine: "Hello") == .plain, "no extension, no shebang")
    expect(Language.detect(fileName: "Makefile", firstLine: nil) == .shell, "known file name")
    expect(Language.detect(fileName: "prices.csv", firstLine: nil) == .csv, "extension: csv")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("text-check-\(getpid())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func roundTrip(_ name: String, _ bytes: Data, edit: (String) -> String = { $0 }) -> (Data, String, String.Encoding) {
        let file = dir.appendingPathComponent(name)
        try! bytes.write(to: file)
        let (text, encoding) = try! FileText.read(file)
        let written = try! FileText.write(edit(text), to: file, encoding: encoding)
        return (try! Data(contentsOf: file), text, written)
    }

    let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])
    let (latinBack, latinText, _) = roundTrip("latin1.txt", latin1)
    expect(latinText == "caf\u{E9}\n", "Latin-1 bytes read as their characters")
    expect(latinBack == latin1, "Latin-1 file saved with the same bytes")
    let utf8 = "na\u{EF}ve \u{1F600}\n".data(using: .utf8)!
    expect(roundTrip("utf8.txt", utf8).0 == utf8, "UTF-8 file saved with the same bytes")
    let utf16 = "hello\n".data(using: .utf16)!
    expect(roundTrip("utf16.txt", utf16).0 == utf16, "UTF-16 file with a BOM keeps its encoding")
    let crlf = "a\r\nb\r\n".data(using: .utf8)!
    expect(roundTrip("crlf.txt", crlf).0 == crlf, "CRLF line endings survive a save")
    let (emojiBack, _, emojiEncoding) = roundTrip("grow.txt", latin1) { $0 + "\u{1F600}" }
    expect(emojiEncoding == .utf8 && String(data: emojiBack, encoding: .utf8) == "caf\u{E9}\n\u{1F600}",
           "text the old encoding cannot hold is saved as UTF-8, not lost")

    let script = dir.appendingPathComponent("run.sh")
    try! "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let link = dir.appendingPathComponent("link.sh")
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
    try! FileText.write("#!/bin/sh\necho bye\n", to: link, encoding: .utf8)
    let linkKind = try! FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
    let scriptMode = try! FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
    expect(linkKind == .typeSymbolicLink, "saving through a symlink keeps the link")
    expect(try! String(contentsOf: script, encoding: .utf8).contains("bye"), "saving through a symlink writes its target")
    expect(scriptMode == 0o755, "a saved script stays executable")
}

if failures > 0 { exit(1) }
print("ok")

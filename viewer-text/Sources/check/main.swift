import Foundation
import TextCore

var failures = 0
func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

func kinds(_ text: String, _ lang: Language, covering needle: String) -> [TokenKind] {
    let r = (text as NSString).range(of: needle)
    return Highlighter(lang).tokens(in: text).filter { NSIntersectionRange($0.range, r).length > 0 }.map(\.kind)
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
expect(kinds("fn f<'a>(x: &'a str)", .rust, covering: "a>(x").isEmpty, "a Rust lifetime is not a string")
expect(kinds(#"{"name": "for"}"#, .json, covering: #""name""#) == [.key], "a JSON key is a key")
expect(kinds(#"{"name": "for"}"#, .json, covering: #""for""#) == [.string], "a JSON value is a string")
expect(kinds("server:\n  port: 8080", .yaml, covering: "port") == [.key], "a YAML key is a key")
expect(kinds("[tool]\nname = \"x\"", .toml, covering: "name") == [.key], "a TOML key is a key")
expect(kinds("# Title\ntext", .markdown, covering: "Title") == [.heading], "a markdown heading")
expect(kinds("```\n# not a heading\n```", .markdown, covering: "not") == [.string], "a fenced block is code")
expect(kinds("<a href=\"x\">", .markup, covering: "<a") == [.tag], "an HTML tag")
expect(kinds("SELECT id FROM t", .sql, covering: "FROM") == [.keyword], "SQL keywords ignore case")
expect(Highlighter(.plain).tokens(in: "let x = 1 // c").isEmpty, "plain text has no colors")

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

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("check: all passed")

import Foundation

public enum TokenKind: Int, CaseIterable, Sendable {
    case comment, string, number, keyword, key, tag, heading
}

public struct Token: Equatable, Sendable {
    public let range: NSRange
    public let kind: TokenKind
}

/// One regex per language, an alternation of one group per token kind. Leftmost match wins, so a
/// `//` inside a string is eaten by the string that starts before it, and a keyword inside a
/// string or comment is never seen on its own.
public final class Highlighter: @unchecked Sendable {
    private let regex: NSRegularExpression?
    private let kinds: [TokenKind]

    public init(_ language: Language) {
        let rules = Grammar.rules(for: language)
        kinds = rules.map(\.0)
        let pattern = rules.map { "(\($0.1))" }.joined(separator: "|")
        regex = rules.isEmpty ? nil : try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    public var colors: Bool { regex != nil }

    public func tokens(in text: String, range: NSRange? = nil) -> [Token] {
        guard let regex else { return [] }
        let whole = range ?? NSRange(location: 0, length: (text as NSString).length)
        var out: [Token] = []
        regex.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match else { return }
            for i in kinds.indices where match.range(at: i + 1).location != NSNotFound {
                out.append(Token(range: match.range(at: i + 1), kind: kinds[i]))
                break
            }
        }
        return out
    }

    private static let cache = NSCache<NSString, Highlighter>()

    public static func shared(_ language: Language) -> Highlighter {
        if let h = cache.object(forKey: language.rawValue as NSString) { return h }
        let h = Highlighter(language)
        cache.setObject(h, forKey: language.rawValue as NSString)
        return h
    }
}

enum Grammar {
    typealias Rule = (TokenKind, String)

    static let dq = #""(?:[^"\\\n]|\\.)*""#
    static let sq = #"'(?:[^'\\\n]|\\.)*'"#
    static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
    static let slashComments = #"//[^\n]*|/\*[\s\S]*?\*/"#
    static let hashComment = #"#[^\n]*"#

    static func words(_ list: String, caseInsensitive: Bool = false) -> String {
        let body = list.split(separator: " ").joined(separator: "|")
        return caseInsensitive ? "(?i:\\b(?:\(body))\\b)" : "\\b(?:\(body))\\b"
    }

    static func code(comment: String, strings: [String], keywords: String) -> [Rule] {
        [(.comment, comment)] + strings.map { (.string, $0) } + [(.number, number), (.keyword, words(keywords))]
    }

    static func rules(for language: Language) -> [Rule] {
        switch language {
        case .swift:
            return code(comment: slashComments, strings: [#""""[\s\S]*?""""#, dq], keywords: Keywords.swift)
        case .python:
            return code(comment: hashComment, strings: [#"[rbfu]{0,2}(?:"""[\s\S]*?"""|'''[\s\S]*?''')"#, dq, sq],
                        keywords: Keywords.python)
        case .javascript:
            return code(comment: slashComments, strings: [dq, sq, #"`(?:[^`\\]|\\.)*`"#], keywords: Keywords.javascript)
        case .c:
            return [(.keyword, #"^\s*#\s*\w+"#)]
                + code(comment: slashComments, strings: [#"@?"# + dq, sq], keywords: Keywords.c)
        case .rust:
            // A single-character literal only: `'a` is a lifetime, not the start of a string.
            return code(comment: slashComments, strings: [dq, #"'(?:[^'\\\n]|\\.)'"#], keywords: Keywords.rust)
        case .go:
            return code(comment: slashComments, strings: [dq, sq, #"`[^`]*`"#], keywords: Keywords.go)
        case .java:
            return code(comment: slashComments, strings: [#""""[\s\S]*?""""#, dq, sq], keywords: Keywords.java)
        case .shell:
            return code(comment: #"(?<![\w$])#[^\n]*"#, strings: [dq, #"'[^']*'"#], keywords: Keywords.shell)
        case .ruby:
            return code(comment: hashComment, strings: [dq, sq], keywords: Keywords.ruby)
        case .sql:
            return [(.comment, #"--[^\n]*|/\*[\s\S]*?\*/"#), (.string, sq), (.string, dq), (.number, number),
                    (.keyword, words(Keywords.sql, caseInsensitive: true))]
        case .lua:
            return code(comment: #"--\[\[[\s\S]*?\]\]|--[^\n]*"#, strings: [dq, sq, #"\[\[[\s\S]*?\]\]"#],
                        keywords: Keywords.lua)
        case .markdown:
            return [(.string, "```[\\s\\S]*?```"), (.heading, #"^#{1,6}[ \t][^\n]*"#), (.string, "`[^`\n]+`"),
                    (.key, #"\[[^\]\n]*\]\([^)\n]*\)"#), (.keyword, #"^[ \t]*(?:[-*+]|\d+\.)(?=[ \t])"#)]
        case .json:
            return [(.key, dq + #"(?=\s*:)"#), (.string, dq), (.number, #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#),
                    (.keyword, words("true false null"))]
        case .yaml:
            return [(.comment, #"(?<!\S)#[^\n]*"#), (.key, #"^[ \t]*(?:- )?[\w.\-/"' ]*?[\w"'](?=:(?:[ \t]|$))"#),
                    (.string, dq), (.string, sq), (.number, number),
                    (.keyword, words("true false null yes no on off"))]
        case .toml:
            return [(.comment, #"^[ \t]*[#;][^\n]*|(?<=\s)#[^\n]*"#), (.heading, #"^[ \t]*\[[^\]\n]*\]+"#),
                    (.key, #"^[ \t]*(?:export[ \t]+)?[\w.\-"]+(?=[ \t]*[=:])"#), (.string, dq), (.string, sq),
                    (.number, number), (.keyword, words("true false"))]
        case .markup:
            return [(.comment, #"<!--[\s\S]*?-->"#), (.tag, #"</?[A-Za-z][\w:.\-]*|/?>"#),
                    (.key, #"\b[\w:\-]+(?==)"#), (.string, dq), (.string, sq)]
        case .plain:
            return []
        }
    }
}

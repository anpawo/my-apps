import Foundation

/// The rules of a programming language, in the order its alternation tries them.
struct Code {
    var comment: String
    var strings: [String]
    var words: Words
    /// Rules tried before the comment (a docstring, a preprocessor line).
    var leading: [Grammar.Rule] = []
    /// Words whose next identifier is a function name (entity.name.function), or a type name.
    var functionDeclarers = ""
    var typeDeclarers = ""
    var extra: [Grammar.Rule] = []
    /// What `@name` is: a Swift attribute is storage.modifier, a Python decorator a function.
    var attribute: TokenKind?
    var allCapsConstants = false
    /// Swift scopes a call as support.function, the others as entity.name.function.
    var call: TokenKind = .function
    /// Swift and Go call capitalized names (`String(x)`, `fmt.Println(x)`): there the call wins.
    var callsBeforeTypes = false
    var types = true
}

enum Grammar {
    typealias Rule = (TokenKind, String)

    static let dq = #""[^"\\\n]*+(?:\\.[^"\\\n]*+)*+""#
    static let sq = #"'[^'\\\n]*+(?:\\.[^'\\\n]*+)*+'"#
    static let tripleOrDoubleDQ = #""(?:""[^"]*+(?:"(?!"")[^"]*+)*+"""|"# + dq.dropFirst() + ")"
    static let number = #"\b(?:0[xX][0-9a-fA-F_]++|0[bB][01_]++|\d[\d_]*+(?:\.\d++)?(?:[eE][+-]?\d++)?)\b"#
    static let slashComments = #"/(?:/[^\n]*+|\*[^*]*+\*++(?:[^/*][^*]*+\*++)*+/)"#
    static let hashComment = #"#[^\n]*"#
    static let identifier = #"[A-Za-z_]\w*"#
    static let swiftIdentifier = #"\b(?:[A-Z]\w*+|[a-z_](?:(?<=\.[a-z_])\w*+|\w*+(?=\()))"#
    static let declarationGuard = #"\b(?=[A-Za-z_])(?<=[ \t])"#
    /// The longest gap between a declaring word and its name a lookbehind may span (ICU needs a bound).
    static let maxGap = 8

    static func pattern(for rules: [Rule]) -> (String, [TokenKind]) {
        let boundary = #"\b"#
        var pattern = ""
        var kinds: [TokenKind] = []
        var inBoundary = false
        var inDeclaration = false

        for (kind, rule) in rules {
            let hasBoundary = rule.hasPrefix(boundary)
            let isDeclaration = hasBoundary && rule.hasPrefix(declarationGuard)
            let prefix = isDeclaration ? declarationGuard : (hasBoundary ? boundary : "")
            let body = rule.dropFirst(prefix.count)

            if hasBoundary == inBoundary, isDeclaration == inDeclaration, kinds.last == kind {
                pattern.removeLast()
                pattern += "|\(body))"
                continue
            }

            if inDeclaration && !isDeclaration { pattern += ")" }
            if inBoundary && !hasBoundary { pattern += ")" }
            if !pattern.isEmpty { pattern += "|" }
            if hasBoundary && !inBoundary { pattern += boundary + "(?:" }
            if isDeclaration && !inDeclaration {
                pattern += declarationGuard.dropFirst(boundary.count) + "(?:"
            }
            pattern += "(\(body))"
            kinds.append(kind)
            inBoundary = hasBoundary
            inDeclaration = isDeclaration
        }

        if inDeclaration { pattern += ")" }
        if inBoundary { pattern += ")" }
        return (pattern, kinds)
    }

    static func words(_ list: String, caseInsensitive: Bool = false) -> String {
        let entries = list.split(separator: " ")
        let body = entries.joined(separator: "|")
        if caseInsensitive { return "(?i:\\b(?:\(body))\\b)" }
        guard entries.allSatisfy({ word in
            word.utf8.allSatisfy {
                (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                    || (0x30...0x39).contains($0) || $0 == 0x5F
            }
        }) else {
            return "\\b(?:\(body))\\b"
        }

        let groups = Dictionary(grouping: entries) { $0.first! }
        let branches = groups.keys.sorted().map { initial -> String in
            let words = groups[initial]!
            if words.count == 1 { return String(words[0]) }
            return "\(initial)(?:\(words.map { $0.dropFirst() }.joined(separator: "|")))"
        }
        return "\\b(?:\(branches.joined(separator: "|")))\\b"
    }

    static func after(_ list: String) -> String {
        let declarers = list.split(separator: " ")
        let endings = String(Set(declarers.compactMap(\.last)).sorted())
        let alternatives = declarers.joined(separator: "|")
        let singleGap = "(?<=[\(endings)][ \\t])(?<=\\b(?:\(alternatives))[ \\t])"
        let multipleGaps = "(?<=[ \\t]{2})(?<=\\b(?:\(alternatives))[ \\t]{2,\(maxGap)})"
        return declarationGuard + "(?:\(singleGap)|\(multipleGaps))" + identifier
    }

    private static func wordLists(_ words: Words) -> [Rule] {
        [(.control, words.control), (.keyword, words.keyword), (.modifier, words.modifier),
         (.literal, words.literal), (.constant, words.language)].filter { !$0.1.isEmpty }
    }

    static let swiftWords: (rules: [Rule], kinds: [String: TokenKind]) = {
        var rules: [Rule] = []
        var kinds: [String: TokenKind] = [:]
        var pending: [Rule] = []

        func flush() {
            if pending.count > 1 && kinds.isEmpty {
                for (kind, list) in pending {
                    for entry in list.split(separator: " ") {
                        let word = String(entry)
                        if kinds[word] == nil { kinds[word] = kind }
                    }
                }
                let trie = wordTrie(kinds.keys.map { $0[...] })
                // CSV and TSV return before examining regex captures.
                rules.append((.column, "\\b(?:\(trie))\\b"))
            } else {
                rules += pending.map { ($0.0, words($0.1)) }
            }
            pending.removeAll(keepingCapacity: true)
        }

        for (kind, list) in wordLists(Keywords.swift) {
            let entries = list.split(separator: " ")
            if !entries.isEmpty && entries.allSatisfy({ $0.utf8.allSatisfy(isWordByte) }) {
                pending.append((kind, list))
            } else {
                flush()
                rules.append((kind, words(list)))
            }
        }
        flush()
        return (rules, kinds)
    }()

    private static func isWordByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 95, 97...122: return true
        default: return false
        }
    }

    private static func wordTrie(_ entries: [Substring]) -> String {
        if entries.count == 1 { return String(entries[0]) }

        let groups = Dictionary(grouping: entries, by: \.first)
        let branches = groups.keys.compactMap { $0 }.sorted().map { initial in
            String(initial) + wordTrie(groups[initial]!.map { $0.dropFirst() })
        }
        let body = branches.joined(separator: "|")
        if groups[nil] != nil { return "(?:\(body))?" }
        return branches.count > 1 ? "(?:\(body))" : body
    }

    static func rules(_ c: Code, wordRules: [Rule]? = nil) -> [Rule] {
        var r = c.leading + [(.comment, c.comment)]
        if !c.strings.isEmpty { r.append((.string, c.strings.joined(separator: "|"))) }
        r.append((.number, number))
        if !c.functionDeclarers.isEmpty { r.append((.function, after(c.functionDeclarers))) }
        if !c.typeDeclarers.isEmpty { r.append((.type, after(c.typeDeclarers))) }
        r += wordRules ?? wordLists(c.words).map { ($0.0, words($0.1)) }
        r += c.extra
        if let kind = c.attribute { r.append((kind, "@" + identifier)) }
        if c.allCapsConstants { r.append((.constant, #"\b[A-Z][A-Z0-9_]+\b"#)) }
        let call: Rule = (c.call, #"\b[A-Za-z_]\w*+(?=\()"#)
        let type: Rule = (.type, #"\b[A-Z]\w*"#)
        if c.types && c.callsBeforeTypes && c.call == .call {
            r.append((.call, swiftIdentifier))
        } else {
            r += !c.types ? [call] : c.callsBeforeTypes ? [call, type] : [type, call]
            r.append((.property, #"\b(?<=\.)[A-Za-z_]\w*"#))
        }
        return r
    }

    static func separator(for language: Language) -> unichar? {
        switch language {
        case .csv: return 0x2C
        case .tsv: return 0x09
        default: return nil
        }
    }

    static func colorsBrackets(_ language: Language) -> Bool {
        ![.markdown, .markup, .plain, .csv, .tsv].contains(language)
    }

    static func rules(for language: Language) -> [Rule] {
        switch language {
        case .swift:
            return rules(Code(comment: slashComments, strings: [tripleOrDoubleDQ], words: Keywords.swift,
                              functionDeclarers: "func", typeDeclarers: "class struct enum protocol extension actor typealias",
                              attribute: .modifier, call: .call, callsBeforeTypes: true),
                         wordRules: swiftWords.rules)
        case .python:
            return rules(Code(comment: hashComment, strings: [#"[rbfuRBFU]{0,2}(?:"""[\s\S]*?"""|'''[\s\S]*?''')"#, dq, sq],
                              words: Keywords.python,
                              // MagicPython: a string standing alone as a statement is a docstring.
                              leading: [(.docstring, #"^[ \t]*[rRuU]?(?:"""[\s\S]*?"""|'''[\s\S]*?''')"#)],
                              functionDeclarers: "def", typeDeclarers: "class", attribute: .function,
                              allCapsConstants: true))
        case .javascript:
            return rules(Code(comment: slashComments, strings: [dq, sq, #"`(?:[^`\\]|\\.)*`"#], words: Keywords.javascript,
                              functionDeclarers: "function", typeDeclarers: "class interface type enum namespace",
                              attribute: .function, allCapsConstants: true))
        case .c:
            return rules(Code(comment: slashComments, strings: [#"@?"# + dq, sq], words: Keywords.c,
                              leading: [(.control, #"^[ \t]*#[ \t]*\w+"#)],
                              typeDeclarers: "class struct enum union namespace", attribute: .modifier,
                              allCapsConstants: true))
        case .rust:
            // A single-character literal only: `'a` is a lifetime, not the start of a string.
            return rules(Code(comment: slashComments, strings: [dq, #"'(?:[^'\\\n]|\\.)'"#], words: Keywords.rust,
                              functionDeclarers: "fn", typeDeclarers: "struct enum trait impl type",
                              extra: [(.function, #"\b[a-z_]\w*!(?=[(\[{])"#)], allCapsConstants: true))
        case .go:
            return rules(Code(comment: slashComments, strings: [dq, sq, #"`[^`]*`"#], words: Keywords.go,
                              functionDeclarers: "func", typeDeclarers: "type", callsBeforeTypes: true))
        case .java:
            return rules(Code(comment: slashComments, strings: [tripleOrDoubleDQ, sq], words: Keywords.java,
                              functionDeclarers: "fun", typeDeclarers: "class interface enum object",
                              attribute: .keyword, allCapsConstants: true))
        case .shell:
            return rules(Code(comment: #"(?<![\w$])#[^\n]*"#, strings: [dq, #"'[^']*'"#], words: Keywords.shell,
                              functionDeclarers: "function", types: false))
        case .ruby:
            return rules(Code(comment: hashComment, strings: [dq, sq], words: Keywords.ruby,
                              functionDeclarers: "def", typeDeclarers: "class module", allCapsConstants: true))
        case .lua:
            return rules(Code(comment: #"--\[\[[\s\S]*?\]\]|--[^\n]*"#, strings: [dq, sq, #"\[\[[\s\S]*?\]\]"#],
                              words: Keywords.lua, functionDeclarers: "function", types: false))
        case .sql:
            return [(.comment, #"--[^\n]*|/\*[\s\S]*?\*/"#), (.string, sq), (.string, dq), (.number, number),
                    (.literal, words("null true false", caseInsensitive: true)),
                    (.keyword, words(Keywords.sql, caseInsensitive: true)), (.call, "\\b" + identifier + "(?=\\()")]
        default:
            return data(language)
        }
    }

    static func data(_ language: Language) -> [Rule] {
        switch language {
        case .markdown:
            return [(.codeBlock, "^```[\\s\\S]*?^```"), (.heading, #"^#{1,6}[ \t][^\n]*"#), (.quote, #"^[ \t]*>[^\n]*"#),
                    (.inlineCode, "`[^`\n]+`"), (.string, #"\[[^\]\n]*\]\([^)\n]*\)"#),
                    (.listMarker, #"^[ \t]*(?:[-*+]|\d+\.)(?=[ \t])"#), (.strong, #"\*\*[^*\n]+\*\*|__[^_\n]+__"#),
                    (.emphasis, #"(?<![\w*])\*[^*\s][^*\n]*\*(?!\*)|(?<!\w)_[^_\s][^_\n]*_(?!\w)"#)]
        case .json:
            return [(.key, dq + #"(?=\s*:)"#), (.string, dq), (.number, #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#),
                    (.literal, words("true false null"))]
        case .yaml:
            // A plain value is a string unless the whole of it is a number or a literal.
            let end = #"(?=[ \t]*(?:#|$))"#
            return [(.comment, #"(?<!\S)#[^\n]*"#), (.key, #"^[ \t]*(?:- )?[\w.\-/"' ]*?[\w"'](?=:(?:[ \t]|$))"#),
                    (.string, dq), (.string, sq), (.number, #"-?\d[\d_]*(?:\.\d+)?"# + end),
                    (.literal, "(?:true|false|null|yes|no|on|off|~)" + end),
                    (.string, #"(?<=[:\-][ \t]{1,8})[^\s#'"\[\]{}|>&*!][^\n]*?"# + end)]
        case .toml:
            // Even Better TOML scopes keys and table names alike, as support.type.property-name.
            return [(.comment, #"^[ \t]*[#;][^\n]*|(?<=\s)#[^\n]*"#), (.attribute, #"^[ \t]*\[[^\]\n]*\]+"#),
                    (.attribute, #"^[ \t]*(?:export[ \t]+)?[\w.\-"]+(?=[ \t]*[=:])"#), (.string, dq), (.string, sq),
                    (.number, number), (.literal, words("true false"))]
        case .markup:
            return [(.comment, #"<!--[\s\S]*?-->"#), (.punctuation, #"</?|/?>"#), (.tag, #"(?<=<|</)[A-Za-z][\w:.\-]*"#),
                    (.attribute, #"\b[\w:\-]+(?==)"#), (.string, dq), (.string, sq)]
        default:
            return []
        }
    }
}

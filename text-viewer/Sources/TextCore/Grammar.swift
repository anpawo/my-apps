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

    static let dq = #""(?:[^"\\\n]|\\.)*""#
    static let sq = #"'(?:[^'\\\n]|\\.)*'"#
    static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
    static let slashComments = #"//[^\n]*|/\*[\s\S]*?\*/"#
    static let hashComment = #"#[^\n]*"#
    static let identifier = #"[A-Za-z_]\w*"#
    /// The longest gap between a declaring word and its name a lookbehind may span (ICU needs a bound).
    static let maxGap = 8

    static func words(_ list: String, caseInsensitive: Bool = false) -> String {
        let body = list.split(separator: " ").joined(separator: "|")
        return caseInsensitive ? "(?i:\\b(?:\(body))\\b)" : "\\b(?:\(body))\\b"
    }

    static func after(_ list: String) -> String {
        "(?<=\\b(?:\(list.split(separator: " ").joined(separator: "|")))[ \\t]{1,\(maxGap)})" + identifier
    }

    static func rules(_ c: Code) -> [Rule] {
        var r = c.leading + [(.comment, c.comment)] + c.strings.map { (.string, $0) } + [(.number, number)]
        if !c.functionDeclarers.isEmpty { r.append((.function, after(c.functionDeclarers))) }
        if !c.typeDeclarers.isEmpty { r.append((.type, after(c.typeDeclarers))) }
        let w = c.words
        r += [(TokenKind.control, w.control), (.keyword, w.keyword), (.modifier, w.modifier),
              (.literal, w.literal), (.constant, w.language)].filter { !$0.1.isEmpty }.map { ($0.0, words($0.1)) }
        r += c.extra
        if let kind = c.attribute { r.append((kind, "@" + identifier)) }
        if c.allCapsConstants { r.append((.constant, #"\b[A-Z][A-Z0-9_]+\b"#)) }
        let call: Rule = (c.call, "\\b" + identifier + "(?=\\()")
        let type: Rule = (.type, #"\b[A-Z]\w*"#)
        r += !c.types ? [call] : c.callsBeforeTypes ? [call, type] : [type, call]
        return r + [(.property, "(?<=\\.)" + identifier)]
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
            return rules(Code(comment: slashComments, strings: [#""""[\s\S]*?""""#, dq], words: Keywords.swift,
                              functionDeclarers: "func", typeDeclarers: "class struct enum protocol extension actor typealias",
                              attribute: .modifier, call: .call, callsBeforeTypes: true))
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
            return rules(Code(comment: slashComments, strings: [#""""[\s\S]*?""""#, dq, sq], words: Keywords.java,
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

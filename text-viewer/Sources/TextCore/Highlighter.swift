import Foundation

/// What a span is, named after the TextMate scope VS Code gives it; the app maps each to the
/// color its theme resolves for that scope.
public enum TokenKind: Int, CaseIterable, Sendable {
    case comment, string, docstring, escape, number
    case keyword, control, modifier, literal, constant
    case function, call, type, property, variable, attribute
    case key, tag, punctuation, heading, inlineCode, codeBlock, listMarker, quote, emphasis, strong
    case column, bracket
}

public struct Token: Equatable, Sendable {
    public let range: NSRange
    public let kind: TokenKind
    /// The column of a `.column` (from 0), the nesting depth of a `.bracket` (from 0).
    public var index = 0
}

/// One regex per language, an alternation of one group per token kind. Leftmost match wins, so a
/// `//` inside a string is eaten by the string that starts before it, and a keyword inside a
/// string or comment is never seen on its own. At one position the first group listed wins.
public final class Highlighter: @unchecked Sendable {
    private let regex: NSRegularExpression?
    private let kinds: [TokenKind]
    private let separator: unichar?
    private let brackets: Bool

    public init(_ language: Language) {
        let rules = Grammar.rules(for: language)
        kinds = rules.map(\.0)
        let pattern = rules.map { "(\($0.1))" }.joined(separator: "|")
        regex = rules.isEmpty ? nil : try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        separator = Grammar.separator(for: language)
        brackets = Grammar.colorsBrackets(language)
    }

    public var colors: Bool { regex != nil || separator != nil }

    public func tokens(in text: String, range: NSRange? = nil) -> [Token] {
        let ns = text as NSString
        let whole = range ?? NSRange(location: 0, length: ns.length)
        if let separator { return Columns.tokens(in: ns, range: whole, separator: separator) }
        guard let regex else { return [] }
        var out: [Token] = []
        regex.enumerateMatches(in: text, range: whole) { match, _, _ in
            guard let match else { return }
            for i in kinds.indices where match.range(at: i + 1).location != NSNotFound {
                let token = Token(range: match.range(at: i + 1), kind: kinds[i])
                out.append(token)
                out += Inner.tokens(inside: token, of: text)
                break
            }
        }
        return brackets ? out + Brackets.tokens(in: ns, range: whole, skipping: out) : out
    }

    private static let cache = NSCache<NSString, Highlighter>()

    public static func shared(_ language: Language) -> Highlighter {
        if let h = cache.object(forKey: language.rawValue as NSString) { return h }
        let h = Highlighter(language)
        cache.setObject(h, forKey: language.rawValue as NSString)
        return h
    }
}

/// Spans inside a token that its grammar colors apart: escapes in strings, the sections and
/// parameters Python Docstring Highlighter marks in a docstring, a fenced block's own language.
enum Inner {
    static let escape = try! NSRegularExpression(
        pattern: #"\\(?:u\{[0-9a-fA-F]{1,8}\}|u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|[nrtbfv0\\"'$`])"#)
    // The extension's own patterns (rodolphebarbanneau.python-docstring-highlighter, base and google).
    static let docHeading = try! NSRegularExpression(
        pattern: #"^[ \t]*(_*(?:[A-Z]\w*(?:[ \t]+(?!$))?)+)(:?)$"#, options: [.anchorsMatchLines])
    static let docParam = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:-[ \t]*)?((?:\*\*|\*)?[a-zA-Z_]\w*(?:\[.*\])?)((?:[ \t]\(.*\))?:)(?=\s)"#,
        options: [.anchorsMatchLines])
    static let docLiteral = try! NSRegularExpression(pattern: "(``)([^`]+)(``)")
    static let fenceInfo = try! NSRegularExpression(pattern: "^```[ \t]*([\\w+#.-]+)[^\\n]*\\n")

    static func tokens(inside token: Token, of text: String) -> [Token] {
        switch token.kind {
        case .string: return matches(escape, in: text, token.range, [.escape])
        case .docstring:
            // `Args:` fits both patterns; the extension lists the heading first, so it wins.
            let headings = matches(docHeading, in: text, token.range, [.escape, .punctuation])
            let params = matches(docParam, in: text, token.range, [.variable, .punctuation]).filter { param in
                !headings.contains { NSIntersectionRange($0.range, param.range).length > 0 }
            }
            return headings + params + matches(docLiteral, in: text, token.range, [.punctuation, .escape, .punctuation])
        case .codeBlock: return fenced(token.range, of: text)
        default: return []
        }
    }

    /// One token per capture group that matched, group n taking `kinds[n - 1]`; with one kind
    /// and no group, the whole match.
    static func matches(_ regex: NSRegularExpression, in text: String, _ range: NSRange,
                        _ kinds: [TokenKind]) -> [Token] {
        var out: [Token] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            if match.numberOfRanges == 1 { out.append(Token(range: match.range, kind: kinds[0])); return }
            for (i, kind) in kinds.enumerated() where match.range(at: i + 1).length > 0 {
                out.append(Token(range: match.range(at: i + 1), kind: kind))
            }
        }
        return out
    }

    static func fenced(_ range: NSRange, of text: String) -> [Token] {
        guard let info = fenceInfo.firstMatch(in: text, range: range) else { return [] }
        let tag = (text as NSString).substring(with: info.range(at: 1)).lowercased()
        let language = Language(rawValue: tag) ?? Language.byInterpreter[tag]
            ?? Language.detect(fileName: "fence." + tag, firstLine: nil)
        guard language != .plain, language != .markdown else { return [] }
        let body = NSRange(location: NSMaxRange(info.range), length: NSMaxRange(range) - NSMaxRange(info.range))
        return Highlighter.shared(language).tokens(in: text, range: body)
    }
}

/// Rainbow CSV: each field (with the separator after it) is one token holding its column.
enum Columns {
    static let quote: unichar = 0x22, newline: unichar = 0x0A, carriageReturn: unichar = 0x0D

    static func tokens(in text: NSString, range: NSRange, separator: unichar) -> [Token] {
        var out: [Token] = []
        var start = range.location, column = 0, quoted = false
        func cut(_ end: Int) {
            if end > start { out.append(Token(range: NSRange(location: start, length: end - start), kind: .column, index: column)) }
            start = end
        }
        for i in range.location..<NSMaxRange(range) {
            let c = text.character(at: i)
            if c == quote && separator != 0x09 {
                quoted.toggle()
            } else if c == newline || c == carriageReturn {
                // Line by line, as Rainbow CSV's grammar: a quote never runs past the line.
                cut(i); start = i + 1; column = 0; quoted = false
            } else if c == separator && !quoted {
                cut(i + 1); column += 1
            }
        }
        cut(NSMaxRange(range))
        return out
    }
}

/// VS Code's bracket pair colorization: one nesting depth across (), [] and {}, brackets inside
/// a string or comment left out.
enum Brackets {
    static let opening: Set<unichar> = [0x28, 0x5B, 0x7B], closing: Set<unichar> = [0x29, 0x5D, 0x7D]

    static func tokens(in text: NSString, range: NSRange, skipping tokens: [Token]) -> [Token] {
        // ponytail: the depth before `range` counts every bracket, strings and comments included,
        // so a "(" in an earlier string shifts the colors of a recolored line; tokenize the
        // prefix if that shows.
        var depth = 0
        for i in 0..<range.location { depth += delta(text.character(at: i)) }
        var out: [Token] = []
        var next = 0
        var i = range.location
        while i < NSMaxRange(range) {
            while next < tokens.count, NSMaxRange(tokens[next].range) <= i { next += 1 }
            if next < tokens.count, tokens[next].range.location <= i { i = NSMaxRange(tokens[next].range); continue }
            let c = text.character(at: i)
            if closing.contains(c) { depth -= 1 }
            if opening.contains(c) || closing.contains(c) {
                out.append(Token(range: NSRange(location: i, length: 1), kind: .bracket, index: max(depth, 0)))
            }
            if opening.contains(c) { depth += 1 }
            i += 1
        }
        return out
    }

    static func delta(_ c: unichar) -> Int { opening.contains(c) ? 1 : closing.contains(c) ? -1 : 0 }
}

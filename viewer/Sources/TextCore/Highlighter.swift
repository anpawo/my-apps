import Foundation

// Tokenizing found by OpenEvolve (~/self/optimization/llm-evolve, viewer-highlight): 5.6x on open, 5.4x per
// edit, the same tokens in the same order on 53 unseen files of 13 types; functions past 50 lines are its
// byte-checked version, kept whole.
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
    private let captures: [(group: Int, kind: TokenKind)]
    private let combinesSwiftIdentifiers: Bool
    private let separator: unichar?
    private let brackets: Bool

    public init(_ language: Language) {
        let rules = Grammar.rules(for: language)
        let (pattern, kinds) = Grammar.pattern(for: rules)
        let commonKinds: [TokenKind] = [.column, .keyword, .call, .type, .function,
                                        .property, .control, .modifier, .string, .comment]
        captures = kinds.enumerated().sorted {
            let left = commonKinds.firstIndex(of: $0.element) ?? commonKinds.count
            let right = commonKinds.firstIndex(of: $1.element) ?? commonKinds.count
            return left == right ? $0.offset < $1.offset : left < right
        }.map { (group: $0.offset + 1, kind: $0.element) }
        combinesSwiftIdentifiers = rules.contains { $0.1 == Grammar.swiftIdentifier }
        regex = rules.isEmpty ? nil : try? NSRegularExpression(
            pattern: pattern, options: [.anchorsMatchLines]
        )
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
            for (group, capturedKind) in captures {
                let capture = match.range(at: group)
                guard capture.location != NSNotFound else { continue }
                let kind: TokenKind
                switch capturedKind {
                case .column:
                    kind = Grammar.swiftWords.kinds[ns.substring(with: capture)]!
                case .call where combinesSwiftIdentifiers:
                    let end = NSMaxRange(capture)
                    if end < NSMaxRange(whole), ns.character(at: end) == 0x28 {
                        kind = .call
                    } else {
                        kind = (0x41...0x5A).contains(ns.character(at: capture.location)) ? .type : .property
                    }
                default:
                    kind = capturedKind
                }
                let token = Token(range: capture, kind: kind)
                out.append(token)
                switch kind {
                case .string:
                    let start = ns.range(of: "\\", options: .literal, range: capture).location
                    if start != NSNotFound {
                        let suffix = NSRange(location: start, length: NSMaxRange(capture) - start)
                        Inner.escape.enumerateMatches(in: text, range: suffix) { escape, _, _ in
                            if let escape {
                                out.append(Token(range: escape.range, kind: .escape))
                            }
                        }
                    }
                case .docstring, .codeBlock:
                    out.append(contentsOf: Inner.tokens(inside: token, of: text))
                default:
                    break
                }
                break
            }
        }
        if brackets {
            Brackets.appendTokens(in: ns, range: whole, to: &out)
        }
        return out
    }

    private static let sharedHighlighters: [String: Highlighter] = {
        let languages: [Language] = [
            .swift, .python, .javascript, .c, .rust, .go, .java, .shell, .ruby, .lua, .sql,
            .markdown, .json, .yaml, .toml, .markup, .plain, .csv, .tsv
        ]
        return Dictionary(uniqueKeysWithValues: languages.map { ($0.rawValue, Highlighter($0)) })
    }()

    public static func shared(_ language: Language) -> Highlighter {
        sharedHighlighters[language.rawValue] ?? Highlighter(language)
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
    static func appendTokens(in text: NSString, range: NSRange, to tokens: inout [Token]) {
        guard range.length > 0 else { return }
        let start = range.location
        let end = NSMaxRange(range)
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: range.length) { units in
            text.getCharacters(units.baseAddress!, range: range)
            var depth = 0
            var needsPrefix = start > 0
            var offset = start

            func scan(until stop: Int) {
                while offset < stop {
                    let change = delta(units[offset - start])
                    if change != 0 {
                        if needsPrefix {
                            depth = prefixDepth(in: text, end: start)
                            needsPrefix = false
                        }
                        let index = max(depth + min(change, 0), 0)
                        tokens.append(Token(range: NSRange(location: offset, length: 1), kind: .bracket, index: index))
                        depth += change
                    }
                    offset += 1
                }
            }

            // Inner tokens can overlap their parent, so the scan cursor only advances.
            for next in 0..<tokens.count {
                let span = tokens[next].range
                scan(until: min(end, span.location))
                offset = max(offset, NSMaxRange(span))
                if offset >= end { break }
            }
            scan(until: end)
        }
    }

    private static func prefixDepth(in text: NSString, end: Int) -> Int {
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: end) { units in
            text.getCharacters(units.baseAddress!, range: NSRange(location: 0, length: end))
            return prefixDepth(units.baseAddress!, end: end)
        }
    }

    private static func prefixDepth(_ units: UnsafePointer<unichar>, end: Int) -> Int {
        typealias Lanes = SIMD8<Int16>
        let width = Lanes.scalarCount
        let vectorEnd = end - end % width
        let maxBatch = Int(Int16.max) / width * width
        let one = Lanes(repeating: 1)
        let bytes = UnsafeRawPointer(units)
        var depth = 0
        var offset = 0

        // Each code unit contributes at most one to the signed horizontal sum.
        while offset < vectorEnd {
            let batchEnd = offset + min(vectorEnd - offset, maxBatch)
            var balance = Lanes.zero
            while offset < batchEnd {
                let chars = bytes.loadUnaligned(
                    fromByteOffset: offset * MemoryLayout<unichar>.stride, as: Lanes.self
                )
                let folded = chars | Lanes(repeating: 0x20)
                let opens = (chars .== Lanes(repeating: 0x28))
                    .| (folded .== Lanes(repeating: 0x7B))
                let closes = (chars .== Lanes(repeating: 0x29))
                    .| (folded .== Lanes(repeating: 0x7D))
                balance = balance &+ Lanes.zero.replacing(with: one, where: opens)
                balance = balance &- Lanes.zero.replacing(with: one, where: closes)
                offset += width
            }
            depth += Int(balance.wrappedSum())
        }
        for position in offset..<end {
            depth += delta(units[position])
        }
        return depth
    }

    static func delta(_ c: unichar) -> Int {
        switch c {
        case 0x28, 0x5B, 0x7B: return 1
        case 0x29, 0x5D, 0x7D: return -1
        default: return 0
        }
    }
}

import AppKit
import TextCore

/// VS Code's built-in "Dark 2026" theme (it includes Dark Modern and overrides most token
/// colors), each token color the one VS Code resolves for that kind's TextMate scope. Menlo 12 is
/// VS Code's macOS default font; it sets lines 18 pt apart.
enum Theme {
    static let fontSize: CGFloat = 12
    static let lineHeight: CGFloat = 18
    static let font = NSFont(name: "Menlo-Regular", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    static let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    static let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)

    static let background = rgb(0x121314)
    static let foreground = rgb(0xbbbebf)
    static let lineNumber = rgb(0x858889)
    static let activeLineNumber = rgb(0xbbbebf)
    static let lineHighlight = rgb(0x242526)
    static let selection = rgb(0x276782, alpha: 0xdd)
    static let sidebarSelection = rgb(0xffffff, alpha: 0x22)
    static let sidebarInactiveSelection = rgb(0x2c2d2e)
    static let sidebarForeground = rgb(0xbfbfbf)
    static let secondary = rgb(0x8c8c8c)
    static let border = rgb(0x2a2b2c)
    static let findMatch = rgb(0x276782, alpha: 0x90)

    static let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]

    /// Rainbow CSV's ten column scopes (rainbow1, keyword.rainbow2, entity.name.function.rainbow3...)
    /// resolved in this theme.
    static let rainbow = [rgb(0xbbbebf), rgb(0xff7b72), rgb(0xd2a8ff), rgb(0x8b949e), rgb(0xa5d6ff),
                          rgb(0xffa657), rgb(0xb5cea8), rgb(0x4ec9b0), rgb(0xc9d1d9), rgb(0xf44747)]
    /// The rainbow column drawn in bold (markup.bold.rainbow9).
    static let boldRainbow = 8
    /// VS Code's default bracket pair colors (editorBracketHighlight.foreground1 to 3).
    static let brackets = [rgb(0xffd700), rgb(0xda70d6), rgb(0x179fff)]

    static func color(_ token: Token) -> NSColor {
        switch token.kind {
        case .comment: return rgb(0x8b949e)
        case .string, .docstring: return rgb(0xa5d6ff)
        case .escape: return rgb(0xd7ba7d)
        case .number: return rgb(0xb5cea8)
        case .keyword: return rgb(0xff7b72)
        case .control: return rgb(0xc586c0)
        case .modifier, .literal: return rgb(0x569cd6)
        case .constant, .heading, .inlineCode: return rgb(0x79c0ff)
        case .function: return rgb(0xd2a8ff)
        case .call: return rgb(0xdcdcaa)
        case .type: return rgb(0x4ec9b0)
        case .property, .emphasis, .strong: return rgb(0xc9d1d9)
        case .variable, .attribute: return rgb(0x9cdcfe)
        case .key, .tag, .quote: return rgb(0x7ee787)
        case .punctuation: return rgb(0x808080)
        case .listMarker: return rgb(0xffa657)
        case .codeBlock: return foreground
        case .column: return rainbow[token.index % rainbow.count]
        case .bracket: return brackets[token.index % brackets.count]
        }
    }

    static func font(_ token: Token) -> NSFont? {
        switch token.kind {
        case .heading, .strong: return bold
        case .emphasis: return italic
        case .column where token.index % rainbow.count == boldRainbow: return bold
        default: return nil
        }
    }

    static func rgb(_ hex: Int, alpha: Int = 0xff) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: CGFloat(alpha) / 255)
    }
}

/// An SF Symbol and a tint per language, for the sidebar.
extension Language {
    var symbol: String {
        switch self {
        case .swift: return "swift"
        case .python, .ruby, .lua: return "chevron.left.forwardslash.chevron.right"
        case .javascript, .c, .rust, .go, .java: return "curlybraces"
        case .shell: return "terminal"
        case .sql: return "cylinder"
        case .markdown: return "doc.richtext"
        case .json: return "curlybraces.square"
        case .yaml, .toml: return "gearshape"
        case .markup: return "chevron.left.slash.chevron.right"
        case .csv, .tsv: return "tablecells"
        case .plain: return "doc.text"
        }
    }

    var tint: NSColor {
        switch self {
        case .swift, .java: return Theme.rgb(0xffa657)
        case .python, .markdown, .c: return Theme.rgb(0x79c0ff)
        case .javascript, .json: return Theme.rgb(0xdcdcaa)
        case .rust, .markup, .ruby: return Theme.rgb(0xff7b72)
        case .go: return Theme.rgb(0x4ec9b0)
        case .shell, .csv, .tsv: return Theme.rgb(0xb5cea8)
        case .yaml, .toml, .lua: return Theme.rgb(0xc586c0)
        case .sql: return Theme.rgb(0xd7ba7d)
        case .plain: return Theme.secondary
        }
    }
}

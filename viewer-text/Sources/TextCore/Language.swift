import Foundation

public enum Language: String, CaseIterable, Sendable {
    case swift, python, javascript, c, rust, go, java, shell, ruby, sql, lua
    case markdown, json, yaml, toml, markup, csv, tsv, plain

    static let byExtension: [String: Language] = [
        "swift": .swift,
        "py": .python, "pyw": .python, "pyi": .python,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .javascript, "tsx": .javascript, "mts": .javascript, "cts": .javascript,
        "c": .c, "h": .c, "cc": .c, "cpp": .c, "cxx": .c, "hpp": .c, "hh": .c, "hxx": .c,
        "m": .c, "mm": .c,
        "rs": .rust, "go": .go,
        "java": .java, "kt": .java, "kts": .java, "scala": .java, "gradle": .java,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell, "command": .shell,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby,
        "sql": .sql, "lua": .lua,
        "md": .markdown, "markdown": .markdown, "mdx": .markdown,
        "json": .json, "jsonl": .json, "geojson": .json,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml, "lock": .toml, "ini": .toml, "cfg": .toml, "conf": .toml, "env": .toml, "gitignore": .toml,
        "properties": .toml, "txt": .plain, "text": .plain, "log": .plain, "csv": .csv, "tsv": .tsv, "tab": .tsv,
        "html": .markup, "htm": .markup, "xml": .markup, "svg": .markup, "plist": .markup,
        "xhtml": .markup, "svelte": .markup, "vue": .markup,
    ]

    static let byName: [String: Language] = [
        "makefile": .shell, "dockerfile": .shell, "gemfile": .ruby, "rakefile": .ruby,
        "podfile": .ruby, "package.swift": .swift, ".env": .toml, ".gitignore": .toml,
        ".zshrc": .shell, ".bashrc": .shell, ".profile": .shell, ".gitconfig": .toml,
    ]

    static let byInterpreter: [String: Language] = [
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell, "dash": .shell, "ksh": .shell,
        "python": .python, "python3": .python, "python2": .python,
        "node": .javascript, "deno": .javascript, "bun": .javascript,
        "ruby": .ruby, "lua": .lua, "swift": .swift,
    ]

    /// Picks the language from the file name, then the shebang of its first line.
    public static func detect(fileName: String, firstLine: String?) -> Language {
        let name = fileName.lowercased()
        if let lang = byName[name] { return lang }
        let ext = (name as NSString).pathExtension
        if let lang = byExtension[ext] { return lang }
        if let line = firstLine, line.hasPrefix("#!") { return fromShebang(line) }
        return .plain
    }

    static func fromShebang(_ line: String) -> Language {
        let words = line.dropFirst(2).split(separator: " ").map(String.init)
        guard var program = words.first.map({ ($0 as NSString).lastPathComponent }) else { return .plain }
        // `#!/usr/bin/env -S python3 -u`: the interpreter is the first word that is not env or a flag.
        if program == "env" { program = words.dropFirst().first { !$0.hasPrefix("-") } ?? "" }
        if let lang = byInterpreter[program] { return lang }
        let base = program.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789."))
        return byInterpreter[base] ?? .plain
    }
}

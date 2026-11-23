import Foundation

public enum FileText {
    /// The file's text and the encoding to save it back with.
    public static func read(_ url: URL) throws -> (String, String.Encoding) {
        var used = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &used) { return (text, used) }
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        // Latin-1 maps every byte, so this never fails and saving writes the same bytes back.
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }

    /// Writes in the file's encoding; text that encoding cannot hold (an emoji typed into a
    /// Latin-1 file) is saved as UTF-8 rather than lost. Returns the encoding written.
    @discardableResult
    public static func write(_ text: String, to url: URL, encoding: String.Encoding) throws -> String.Encoding {
        let used = text.data(using: encoding) != nil ? encoding : .utf8
        guard let data = text.data(using: used) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        // An atomic write puts a new file in place: it would turn a symlinked dotfile into a copy
        // and drop a script's executable bit, so write through the link and put the mode back.
        let target = url.resolvingSymlinksInPath()
        let mode = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path) }
        return used
    }

    public static func firstLine(_ text: String) -> String {
        String(text.prefix(while: { $0 != "\n" && $0 != "\r" }))
    }
}

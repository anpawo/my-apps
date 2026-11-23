import Foundation
import UniformTypeIdentifiers

public enum Speed {
    public static let steps: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    /// Moves `delta` steps from the step nearest `current`, clamped to both ends.
    public static func step(_ current: Double, by delta: Int) -> Double {
        let nearest = steps.indices.min { abs(steps[$0] - current) < abs(steps[$1] - current) }!
        return steps[min(max(nearest + delta, 0), steps.count - 1)]
    }

    public static func label(_ speed: Double) -> String { String(format: "%g×", speed) }
}

public enum Volume {
    public static let step: Float = 0.1

    public static func step(_ current: Float, by delta: Int) -> Float {
        let tenths = (current / step).rounded() + Float(delta)
        return min(max(tenths * step, 0), 1)
    }

    public static func label(_ volume: Float) -> String { "Volume \(Int((volume * 100).rounded()))%" }
}

public enum Kind: CaseIterable, Equatable, Sendable {
    case video, gif, image, music, pdf, text

    /// Text kinds macOS has no type for; Info.plist declares them too, so Finder offers this app.
    public static let textExtensions: Set<String> = ["jsonl", "conf", "env", "kt", "kts", "fish", "svelte", "scala",
        "zig", "nim", "toml", "ini", "cfg", "lock", "gitignore", "cjs", "tsx", "jsx", "rs", "go", "sql", "scss", "less",
        "vue", "gradle", "properties", "dart"]

    public init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            if Self.looksLikeText(url) { self = .text; return }
            return nil
        }
        if Self.isTypeScript(url) { self = .text; return }
        if type.conforms(to: .gif) { self = .gif }
        else if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .audio) { self = .music }
        else if type.conforms(to: .audiovisualContent) { self = .video }
        else if type.conforms(to: .text) || type.conforms(to: .sourceCode)
                    || Self.textExtensions.contains(url.pathExtension.lowercased()) { self = .text }
        else if type.isDynamic && Self.looksLikeText(url) { self = .text }
        else { return nil }
    }

    private static let sniffLength = 8192

    /// A file macOS has no type for (no extension, or one nothing declares) is text when its start
    /// holds no NUL byte, the test git uses to tell text from binary.
    private static func looksLikeText(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return !file.readData(ofLength: sniffLength).contains(0)
    }

    private static let transportPacket = 188
    private static let transportSync: UInt8 = 0x47

    /// `.ts` and `.mts` name TypeScript as often as an MPEG transport stream; a stream has the sync
    /// byte at the start of each 188-byte packet, so a file lacking it at 0 and 188 is code.
    private static func isTypeScript(_ url: URL) -> Bool {
        guard ["ts", "mts"].contains(url.pathExtension.lowercased()) else { return false }
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        let head = [UInt8](file.readData(ofLength: transportPacket + 1))
        return head.count <= transportPacket || head[0] != transportSync || head[transportPacket] != transportSync
    }

    /// Speed, play and volume mean something for these.
    public var plays: Bool { self == .video || self == .gif || self == .music }
}

/// The files to load from what was opened: a folder gives the files it can show directly inside it.
public func mediaFiles(in urls: [URL]) -> [URL] {
    urls.flatMap { url -> [URL] in
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return Kind(url: url) == nil ? [] : [url]
        }
        let inside = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return inside.filter { Kind(url: $0) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

public enum Timeline {
    /// Browsers play a GIF delay this short at `defaultDelay`: files rely on it.
    static let tooShortDelay = 0.011
    static let defaultDelay = 0.1

    public static func delay(_ raw: Double?) -> Double {
        guard let raw, raw >= tooShortDelay else { return defaultDelay }
        return raw
    }

    /// The frame showing `time` seconds in, given each frame's duration.
    public static func frame(at time: Double, durations: [Double]) -> Int {
        var end = 0.0
        for (index, duration) in durations.enumerated() {
            end += duration
            if time < end { return index }
        }
        return max(durations.count - 1, 0)
    }

    public static func start(of frame: Int, durations: [Double]) -> Double {
        durations.prefix(frame).reduce(0, +)
    }
}

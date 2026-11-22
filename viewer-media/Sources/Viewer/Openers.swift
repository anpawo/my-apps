import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Shared by Viewer Media and Viewer Text (viewer-text links to this file).
/// The Settings window (⌘,): every file kind this app can open, and the app macOS opens each with by default.
enum Openers {
    struct Row: Identifiable {
        let ext: String
        let opener: String
        var id: String { ext }
    }

    private static let windowSize = NSSize(width: 460, height: 560)
    private static var window: NSWindow?

    /// `extensions` names the common ones; the app's Info.plist adds those it declares by name.
    static func rows(_ extensions: [String]) -> (here: [Row], elsewhere: [Row]) {
        let me = Bundle.main.bundleIdentifier
        var here: [Row] = [], elsewhere: [Row] = []
        for ext in Array(NSOrderedSet(array: extensions + declaredExtensions())) as! [String] {
            guard let type = UTType(filenameExtension: ext) else { continue }
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: type).compactMap { Bundle(url: $0)?.bundleIdentifier }
            guard apps.contains(where: { $0 == me }) else { continue }
            let opener = NSWorkspace.shared.urlForApplication(toOpen: type)
            if Bundle(url: opener ?? URL(fileURLWithPath: "/"))?.bundleIdentifier == me {
                here.append(Row(ext: ext, opener: ""))
            } else {
                elsewhere.append(Row(ext: ext, opener: opener?.deletingPathExtension().lastPathComponent ?? "nothing"))
            }
        }
        return (here, elsewhere)
    }

    private static func declaredExtensions() -> [String] {
        let docs = Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let named = docs.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
        let typed = docs.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
            .flatMap { UTType($0)?.tags[.filenameExtension] ?? [] }
        return named + typed
    }

    static func view(_ extensions: [String]) -> NSView {
        let (here, elsewhere) = rows(extensions)
        let view = NSHostingView(rootView: OpenersView(here: here, elsewhere: elsewhere))
        view.frame = NSRect(origin: .zero, size: windowSize)
        return view
    }

    static func show(_ extensions: [String]) {
        let win = window ?? NSWindow(contentRect: NSRect(origin: .zero, size: windowSize),
                                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Settings"
        win.isReleasedWhenClosed = false
        win.contentView = view(extensions)
        if window == nil { win.center() }
        window = win
        win.makeKeyAndOrderFront(nil)
    }

    /// `--render-settings out.png`: the Settings content drawn offscreen.
    @MainActor static func render(_ extensions: [String], to out: URL) -> Bool {
        let (here, elsewhere) = rows(extensions)
        let renderer = ImageRenderer(content: OpenersView(here: here, elsewhere: elsewhere).content
            .frame(width: windowSize.width).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: out)) != nil
    }
}

private struct OpenersView: View {
    let here: [Openers.Row]
    let elsewhere: [Openers.Row]
    static let perLine = 4
    static let cellWidth: CGFloat = 105

    var body: some View { ScrollView { content } }

    var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Opens here by default (\(here.count))").font(.headline)
            ForEach(Array(stride(from: 0, to: here.count, by: Self.perLine)), id: \.self) { start in
                HStack(spacing: 0) {
                    ForEach(here[start..<min(start + Self.perLine, here.count)]) { row in
                        Text("." + row.ext).font(.body.monospaced()).frame(width: Self.cellWidth, alignment: .leading)
                    }
                }
            }
            Divider()
            Text("Can open, but opens with another app (\(elsewhere.count))").font(.headline)
            ForEach(elsewhere) { row in
                HStack {
                    Text("." + row.ext).font(.body.monospaced())
                    Spacer()
                    Text(row.opener).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

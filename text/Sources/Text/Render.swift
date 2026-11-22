import AppKit

/// `text --render out.png file...`: the window laid out offscreen with those files open (the
/// first one shown), drawn into a PNG, then exit. How its look is checked without a window.
enum Render {
    static let settle: TimeInterval = 0.2

    static func run(out: URL, files: [URL]) -> Never {
        NSApp.setActivationPolicy(.prohibited)
        let main = MainWindow()
        main.window.setContentSize(MainWindow.size)
        main.open(files)
        main.show(main.docs.first)
        let root = main.window.contentView!
        root.layoutSubtreeIfNeeded()
        main.textView.layoutManager?.ensureLayout(for: main.textView.textContainer!)
        // The table adds rows on its next pass: give it one.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: settle))
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { fail("no bitmap") }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("no PNG") }
        do { try png.write(to: out) } catch { fail(error.localizedDescription) }
        print(out.path)
        exit(0)
    }

    static func fail(_ why: String) -> Never {
        FileHandle.standardError.write(Data("render: \(why)\n".utf8))
        exit(1)
    }
}

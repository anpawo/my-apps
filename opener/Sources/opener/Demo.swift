import AppKit
import Carbon.HIToolbox
import SwiftUI

/// `opener --render-demo <dir>`: the README's GIF as frames, one PNG per change, and `list.txt`, an ffmpeg concat list
/// of how long each stays up. ⌘Space, "saf" and ↵ on Safari; ⌘Space again, "te", ↓ and ↵ on TextEdit. Each key goes
/// through `Opener.key` and the panel is `OpenerView`, drawn offscreen, except ↵: it would open the app, so the frame
/// shows what `Opener.open` would open instead. `docs/make-demo.sh` makes the GIF.
@MainActor
enum Demo {
    /// A desktop cropped around the panel, in points; drawn at twice that.
    static let screen = CGRect(x: 0, y: 0, width: 960, height: 624)

    static func render(to dir: URL) {
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The apps every Mac has rather than this one's, and no count of past opens to reorder them.
        UserDefaults.standard.setVolatileDomain(["uses": [String: Int]()], forName: UserDefaults.argumentDomain)
        let opener = Opener()
        opener.apps = Catalog.apps(in: ["/System/Applications", "/System/Applications/Utilities",
                                        "/System/Cryptexes/App/System/Applications"])
        let desk = canvas { wallpaper() }
        var up = false, windows: [(picture: NSImage, frame: CGRect, alpha: CGFloat)] = []
        var caps: [(label: String, down: Bool)] = [], note: String?
        var list = "", count = 0

        func frame(_ seconds: Double) {
            // ffmpeg reads the frames at 25 fps: off its 40 ms grid, a duration comes out longer and shorter by turns.
            precondition(abs(seconds * 25 - (seconds * 25).rounded()) < 1e-6, "\(seconds) s is not a multiple of 40 ms")
            let pic = canvas {
                desk.draw(in: screen)
                for w in windows {
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor(white: 0, alpha: 0.4 * w.alpha)
                    shadow.shadowBlurRadius = 30
                    shadow.shadowOffset = CGSize(width: 0, height: -12)
                    shadow.set()
                    w.picture.draw(in: w.frame, from: .zero, operation: .sourceOver, fraction: w.alpha)
                    NSGraphicsContext.restoreGraphicsState()
                }
                if up { panel(opener).draw(in: Opener.frame(in: screen)) }
                keys(caps, note)
            }
            count += 1
            let name = String(format: "%03d.png", count)
            try! pic.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
            list += "file '\(name)'\nduration \(seconds)\n"
        }
        /// The chord `toggle` answers: the panel up and empty, minus the window it orders in.
        func chord() {
            caps = [("⌘", true), ("Space", false)]
            frame(0.2)
            caps[1].down = true
            opener.type("")
            up = true
            frame(0.16)
            for i in caps.indices { caps[i].down = false }
            frame(0.44)
        }
        /// A key through `Opener.key`, lit while it is down.
        func press(_ code: Int, _ chars: String, _ label: String, hold: Double) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: UInt16(code))!
            precondition(opener.key(event), "opener did not take \(label)")
            caps = [(label, true)]
            frame(0.08)
            caps[0].down = false
            frame(hold)
        }
        func type(_ word: String, hold: Double) {
            let codes: [Character: Int] = ["a": kVK_ANSI_A, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "s": kVK_ANSI_S, "t": kVK_ANSI_T]
            for (i, c) in word.enumerated() {
                press(codes[c]!, String(c), c.uppercased(), hold: i == word.count - 1 ? hold : 0.12)
            }
        }
        /// ↵ as `Opener.open` takes it: the panel goes and the app starts; a stand-in window of it comes up.
        func open(_ name: String, at rect: CGRect, _ picture: (CGSize) -> NSImage) {
            let app = opener.results[opener.index]
            precondition(app.name == name, "↵ would open \(app.name), not \(name)")
            up = false
            caps = [("↵", true)]
            note = "opens \(name)"
            frame(0.12)
            caps[0].down = false
            frame(0.36)
            windows.append((picture(rect.size), rect, 0))
            for a in [0.35, 0.7, 1.0] {
                windows[windows.count - 1].alpha = a
                frame(0.04)
            }
            frame(1.2)
            caps = []
            note = nil
            frame(0.4)
        }

        frame(0.8)
        chord()
        type("saf", hold: 0.6)
        // Clear of the keys at the foot, TextEdit cascading down and right of Safari.
        open("Safari", at: CGRect(x: 100, y: 104, width: 760, height: 470), safari)
        chord()
        type("te", hold: 0.6)
        press(kVK_DownArrow, "\u{F701}", "↓", hold: 0.6)
        open("TextEdit", at: CGRect(x: 380, y: 84, width: 500, height: 340), textEdit)
        // The concat demuxer drops the last frame's duration unless the frame comes again.
        list += "file '\(String(format: "%03d.png", count))'\n"
        try! list.write(to: dir.appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
        print("wrote \(count) frames and list.txt to \(dir.path)")
    }

    private static func panel(_ opener: Opener) -> NSImage {
        let renderer = ImageRenderer(content: OpenerView(opener: opener)
            .frame(width: Opener.size.width, height: Opener.size.height)
            .environment(\.colorScheme, .light))
        renderer.scale = 2
        return renderer.nsImage!
    }

    private static func canvas(_ draw: () -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(screen.width * 2), pixelsHigh: Int(screen.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = screen.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Sonoma's stock wallpaper, square: the screen filled from its middle band rather than squashed.
    private static func wallpaper() {
        let wall = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Sonoma.heic")!
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let h = CGFloat(wall.width) * screen.height / screen.width
        NSImage(cgImage: wall, size: .zero).draw(in: screen, from: CGRect(x: 0, y: (CGFloat(wall.height) - h) / 2,
                                                                          width: CGFloat(wall.width), height: h),
                                                 operation: .copy, fraction: 1)
    }

    /// The keys pressed, lit while down, then what the last one did, at the foot of the screen.
    private static func keys(_ caps: [(label: String, down: Bool)], _ note: String?) {
        let font = NSFont.systemFont(ofSize: 16, weight: .medium), height: CGFloat = 36, gap: CGFloat = 8
        let dark = NSColor(white: 0.12, alpha: 0.85), blue = NSColor(srgbRed: 0.04, green: 0.45, blue: 0.95, alpha: 1)
        func text(_ s: String, _ alpha: CGFloat) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: alpha)])
        }
        var items: [(text: NSAttributedString, width: CGFloat, fill: NSColor, radius: CGFloat)] = caps.map {
            let t = text($0.label, $0.down ? 1 : 0.7)
            return (t, max(40, (t.size().width + 28).rounded()), $0.down ? blue : dark, 8)
        }
        if let note {
            let t = text(note, 1)
            items.append((t, (t.size().width + 32).rounded(), dark, height / 2))
        }
        var x = ((screen.width - items.reduce(-gap) { $0 + $1.width + gap }) / 2).rounded()
        for item in items {
            let r = CGRect(x: x, y: 28, width: item.width, height: height)
            item.fill.setFill()
            NSBezierPath(roundedRect: r, xRadius: item.radius, yRadius: item.radius).fill()
            item.text.draw(at: CGPoint(x: r.midX - item.text.size().width / 2, y: r.midY - item.text.size().height / 2))
            x += item.width + gap
        }
    }

    /// A stand-in for the app that opened, nothing of anyone's in it: a window's frame, its traffic lights centred in
    /// a title bar `bar` high, and `content` under them.
    private static func window(_ size: CGSize, bar: CGFloat, _ content: @escaping (CGRect) -> Void) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            let outline = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            NSColor.white.setFill()
            r.fill()
            content(r)
            for (i, rgb) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
                NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).setFill()
                NSBezierPath(ovalIn: CGRect(x: 20 + CGFloat(i) * 20, y: r.maxY - bar / 2 - 6, width: 12, height: 12)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 0, alpha: 0.12).setStroke()
            outline.stroke()
            return true
        }
    }

    private static func label(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ gray: CGFloat) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                   .foregroundColor: NSColor(white: gray, alpha: 1)])
    }

    /// Safari's start page: the address field and a row of favourites, blank.
    private static func safari(_ size: CGSize) -> NSImage {
        window(size, bar: 52) { r in
            NSColor(white: 0.965, alpha: 1).setFill()
            CGRect(x: 0, y: r.maxY - 52, width: r.width, height: 52).fill()
            let field = CGRect(x: (r.width * 0.29).rounded(), y: r.maxY - 41, width: (r.width * 0.42).rounded(), height: 30)
            NSColor(white: 0.9, alpha: 1).setFill()
            NSBezierPath(roundedRect: field, xRadius: 15, yRadius: 15).fill()
            let hint = label("Search or enter website name", 13, .regular, 0.55)
            hint.draw(at: CGPoint(x: field.midX - hint.size().width / 2, y: field.midY - hint.size().height / 2))
            let title = label("Favorites", 17, .bold, 0.15)
            let left = (r.width * 0.16).rounded()
            title.draw(at: CGPoint(x: left, y: r.maxY - 112))
            for i in 0..<6 {
                let x = left + CGFloat(i) * 92
                NSColor(white: 0.9, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: r.maxY - 196, width: 64, height: 64), xRadius: 14, yRadius: 14).fill()
                NSColor(white: 0.86, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: x + 8, y: r.maxY - 216, width: 48, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
            }
        }
    }

    /// A new TextEdit document: "Untitled", empty, the caret at its start.
    private static func textEdit(_ size: CGSize) -> NSImage {
        window(size, bar: 34) { r in
            NSColor(white: 0.965, alpha: 1).setFill()
            CGRect(x: 0, y: r.maxY - 34, width: r.width, height: 34).fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            CGRect(x: 0, y: r.maxY - 35, width: r.width, height: 1).fill()
            let title = label("Untitled", 13, .semibold, 0.3)
            title.draw(at: CGPoint(x: r.midX - title.size().width / 2, y: r.maxY - 17 - title.size().height / 2))
            NSColor(white: 0.1, alpha: 1).setFill()
            CGRect(x: 24, y: r.maxY - 70, width: 1.5, height: 18).fill()
        }
    }
}

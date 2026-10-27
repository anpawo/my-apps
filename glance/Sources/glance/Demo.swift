import AppKit
import CoreImage
import SwiftUI

/// `glance --render-demo <dir>`: the README's GIF as frames, one PNG per change, and `list.txt`, an ffmpeg concat list of
/// how long each stays up. A terminal with a script that fails; ⌘⌥G and ↵ on nothing typed; a follow-up in French;
/// ⌘C; ⎋. The panel is `GlanceView`, drawn offscreen, and its answers are the ones `glance --ask` gave on the first
/// frame (`docs/make-demo.sh --ask-again`), so the GIF shows what the app does, not what it might. Frame 001 is that
/// screen alone.
@MainActor
enum Demo {
    /// A desktop, in points; drawn at twice that.
    static let screen = CGRect(x: 0, y: 0, width: 1100, height: 720)

    static let terminal = """
    ~ % cat stats.py
    import csv, sys

    def mean(values):
        return sum(values) / len(values)

    with open(sys.argv[1]) as f:
        totals = [float(r["total"]) for r in csv.DictReader(f) if r.get("total")]
    print(f"average: {mean(totals):.2f}")
    ~ % python3 stats.py orders.csv
    Traceback (most recent call last):
      File "/Users/me/stats.py", line 8, in <module>
        print(f"average: {mean(totals):.2f}")
                          ~~~~^^^^^^^^
      File "/Users/me/stats.py", line 4, in mean
        return sum(values) / len(values)
               ~~~~~~~~~~~~^~~~~~~~~~~~~
    ZeroDivisionError: division by zero
    ~ % head -3 orders.csv
    id;customer;total
    1;Alice;19.90
    2;Bob;7.50
    ~ %
    """

    static let followUp = "et si le fichier est vide ?"

    /// What `glance --ask <frames>/001.png "" "et si le fichier est vide ?"` answered, Opus, 27/10/2026 (`docs/make-demo.sh`).
    static let answers = [
        """
        The CSV is semicolon-separated, but `csv.DictReader` splits on commas by default. Fix line 7:

        ```python
            totals = [float(r["total"]) for r in csv.DictReader(f, delimiter=";") if r.get("total")]
        ```

        - With the default delimiter, each row is read as a single column named `"id;customer;total"`. There is no `"total"` key, so `r.get("total")` is always `None`.
        - That leaves `totals` empty, and `len([])` is 0, which causes the division by zero.

        To make `mean` safe when a file really has no rows:

        ```python
        def mean(values):
            return sum(values) / len(values) if values else 0.0
        ```
        """,
        """
        Avec la garde dans `mean`, un fichier vide (ou avec seulement l'en-tête) affiche `average: 0.00` sans planter. C'est trompeur, mieux vaut le signaler explicitement :

        ```python
        with open(sys.argv[1]) as f:
            totals = [float(r["total"]) for r in csv.DictReader(f, delimiter=";") if r.get("total")]

        if not totals:
            sys.exit("aucune valeur 'total' trouvée")

        print(f"average: {mean(totals):.2f}")
        ```

        - Fichier totalement vide : `DictReader` ne lit aucun en-tête et ne produit aucune ligne, donc `totals` est vide.
        - En-tête seul : même résultat.
        - `sys.exit("...")` affiche le message sur stderr et sort avec le code 1, ce qui est pratique si le script est appelé depuis un autre outil.
        """,
    ]

    static func render(to dir: URL) {
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let glance = Glance()
        let desk = desktop(), glass = behind(desk)
        var up = false, caps: [(label: String, down: Bool)] = [], note: String?
        var list = "", count = 0

        func frame(_ seconds: Double) {
            // ffmpeg reads the frames at 25 fps: off its 40 ms grid, a duration comes out longer and shorter by turns.
            precondition(abs(seconds * 25 - (seconds * 25).rounded()) < 1e-6, "\(seconds) s is not a multiple of 40 ms")
            let pic = canvas {
                desk.draw(in: screen)
                if up { drawPanel(glance, glass) }
                keys(caps, note)
            }
            count += 1
            let name = String(format: "%03d.png", count)
            try! pic.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
            list += "file '\(name)'\nduration \(seconds)\n"
        }
        func press(_ label: [String], _ action: () -> Void, hold: Double, says: String? = nil) {
            caps = label.map { ($0, true) }
            note = says
            action()
            frame(0.12)
            for i in caps.indices { caps[i].down = false }
            frame(hold)
        }
        /// The answer as it streams: a few words a frame.
        func stream(_ answer: String) {
            let words = answer.split(separator: " ", omittingEmptySubsequences: false)
            stride(from: 0, to: words.count, by: 4).forEach { i in
                glance.receive(.text(words[i..<min(i + 4, words.count)].joined(separator: " ") + (i + 4 < words.count ? " " : "")))
                frame(0.04)
            }
            glance.receive(.done(answer))
        }

        frame(1.6)
        press(["⌘", "⌥", "G"], {
            (up, glance.seesScreen) = (true, true)
        }, hold: 0.6, says: "opens on the screen as it is")
        press(["↵"], {
            (glance.seesScreen, caps) = (false, [("↵", true)])
            glance.turns = [Glance.Turn(question: "", withScreen: true)]
        }, hold: 0.8, says: "nothing typed: help with what is there")
        (caps, note) = ([], nil)
        stream(answers[0])
        frame(3.2)
        for c in followUp {
            glance.draft.append(c)
            frame(0.04)
        }
        frame(0.4)
        press(["↵"], {
            glance.draft = ""
            // The panel scrolls the new question to its top, past the first answer: two answers are more than its room.
            glance.turns = [Glance.Turn(question: followUp, withScreen: false)]
        }, hold: 0.6, says: "a follow-up, in French")
        (caps, note) = ([], nil)
        stream(answers[1])
        frame(3.2)
        press(["⌘", "C"], { glance.copied = true }, hold: 1.0, says: "copies the code")
        glance.copied = false
        press(["⎋"], { up = false }, hold: 1.2, says: "closes, and the conversation ends")
        (caps, note) = ([], nil)
        frame(0.8)
        // The concat demuxer drops the last frame's duration unless the frame comes again.
        list += "file '\(String(format: "%03d.png", count))'\n"
        try! list.write(to: dir.appendingPathComponent("list.txt"), atomically: true, encoding: .utf8)
        print("wrote \(count) frames and list.txt to \(dir.path)")
    }

    /// `glance --render <png>`: the demo's screen with its first answer up.
    static func still(to url: URL) {
        let glance = Glance()
        glance.turns = [Glance.Turn(question: "", withScreen: true, answer: answers[0], done: true)]
        let desk = desktop()
        let pic = canvas { desk.draw(in: screen); drawPanel(glance, behind(desk)) }
        try! pic.representation(using: .png, properties: [:])!.write(to: url)
        print("wrote \(url.path)")
    }

    private static func desktop() -> NSBitmapImageRep {
        canvas { wallpaper(); window(CGRect(x: 150, y: 84, width: 800, height: 500)) }
    }

    /// Where ⌘⌥G puts it, as `Glance.frame` says.
    private static func drawPanel(_ glance: Glance, _ glass: NSImage) {
        let frame = Glance.frame(screen: screen, visible: screen)
        glance.size = frame.insetBy(dx: Glance.margin, dy: Glance.margin).size
        let renderer = ImageRenderer(content: GlanceView(glance: glance, scrolls: false).environment(\.renderBehind, glass))
        renderer.scale = 2
        renderer.nsImage!.draw(in: frame)
    }

    /// What the glass shows of `desk`, from the card's top-left corner down: blurred 40 pt and through the matrix, on
    /// sRGB values with no working colour space, as `Glass` does on the screen.
    private static func behind(_ desk: NSBitmapImageRep) -> NSImage {
        let scale = CGFloat(desk.pixelsWide) / screen.width, m = Glass.matrix
        let image = CIImage(cgImage: desk.cgImage!).clampedToExtent().applyingGaussianBlur(sigma: 40 * scale)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: 0),
                "inputGVector": CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: 0),
                "inputBVector": CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: 0)])
        // Core Image counts from the bottom: from there up to the card's top.
        let card = Glance.frame(screen: screen, visible: screen).insetBy(dx: Glance.margin, dy: Glance.margin)
        let pixels = CGRect(x: card.minX * scale, y: 0, width: card.width * scale, height: card.maxY * scale)
        let out = CIContext(options: [.workingColorSpace: NSNull()])
            .createCGImage(image, from: pixels, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        return NSImage(cgImage: out, size: CGSize(width: card.width, height: card.maxY))
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

    /// Sonoma's stock wallpaper, filled from its middle band rather than squashed (opener's demo does the same).
    private static func wallpaper() {
        let wall = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Sonoma.heic")!
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let h = CGFloat(wall.width) * screen.height / screen.width
        NSImage(cgImage: wall, size: .zero).draw(in: screen, from: CGRect(x: 0, y: (CGFloat(wall.height) - h) / 2,
                                                                          width: CGFloat(wall.width), height: h),
                                                 operation: .copy, fraction: 1)
    }

    /// A dark terminal window with `terminal` in it, its traffic lights in a title bar.
    private static func window(_ frame: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.4)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = CGSize(width: 0, height: -12)
        shadow.set()
        let outline = NSBezierPath(roundedRect: frame, xRadius: 16, yRadius: 16)
        NSColor(white: 0.11, alpha: 1).setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        for (i, rgb) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: frame.minX + 18 + CGFloat(i) * 20, y: frame.maxY - 23, width: 12, height: 12)).fill()
        }
        let title = NSAttributedString(string: "zsh", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                                       .foregroundColor: NSColor(white: 0.6, alpha: 1)])
        title.draw(at: CGPoint(x: frame.midX - title.size().width / 2, y: frame.maxY - 25))
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 19
        style.maximumLineHeight = 19
        let red = NSColor(srgbRed: 1, green: 0.42, blue: 0.4, alpha: 1)
        let text = NSMutableAttributedString()
        for line in terminal.split(separator: "\n", omittingEmptySubsequences: false) {
            let color = line.hasPrefix("ZeroDivisionError") ? red : line.hasPrefix("~ %") ? NSColor(white: 1, alpha: 1) : NSColor(white: 0.82, alpha: 1)
            text.append(NSAttributedString(string: line + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                                                             .foregroundColor: color, .paragraphStyle: style]))
        }
        text.draw(in: CGRect(x: frame.minX + 20, y: frame.minY + 12, width: frame.width - 40, height: frame.height - 52))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The keys pressed, lit while down, then what they did, at the foot of the screen (as in opener's demo).
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
}

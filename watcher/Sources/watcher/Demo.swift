import AppKit
import Carbon.HIToolbox
import CoreImage
import SwiftUI

/// `watcher --render-demo <dir>`: the README's GIF as frames, and `list.txt`, ffmpeg's concat list of how long each
/// stays up. The panel's own views, driven through `Inbox.key` on made-up lines and checks in a scratch folder, over a
/// stock wallpaper. Nothing is put on screen and ↵ opens nothing. `docs/make-demo.sh` makes the GIF.
@MainActor
enum Demo {
    /// A small screen, so the panel still reads once the GIF is scaled down.
    static let size = CGSize(width: 1040, height: 720)
    static let scale: CGFloat = 2
    static let px = CGSize(width: size.width * scale, height: size.height * scale)
    static let full = CGRect(origin: .zero, size: px)

    static func render(to dir: URL) {
        _ = NSApplication.shared
        let fm = FileManager.default
        let state = fm.temporaryDirectory.appending(path: "watcher-demo-\(getpid())")
        let folder = state.appending(path: "inbox")
        try? fm.createDirectory(at: state.appending(path: "fired"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: state) }

        // Fixed hours of today, so the dates read the same at every render.
        let today = Calendar.current.startOfDay(for: Date())
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Double {
            Calendar.current.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: today)!.timeIntervalSince1970 * 1000
        }
        func line(_ id: String, _ when: Double, _ kind: String, _ subject: String, _ text: String) {
            let item = InboxItem(id: id, at: when, kind: kind, subject: subject, line: text, dir: "/", options: ["--resume", id], prompt: nil)
            try? JSONEncoder().encode(item).write(to: folder.appending(path: "\(id).json"))
        }
        // As the checker writes them: a chat is WhatsApp, a cmd a command, neither Gmail.
        func check(_ id: String, _ fields: [String: Any], fired: Double? = nil) {
            var json = fields
            json["id"] = id
            if let fired { json["fired"] = ["at": fired] }
            try? JSONSerialization.data(withJSONObject: json).write(to: state.appending(path: fired == nil ? "\(id).json" : "fired/\(id).json"))
        }
        line("parcel", at(0, 9, 12), "done", "Parcel at the pickup point",
             "The Contoso parcel is at the pickup point by the station; its code is in your todos.")
        line("interview", at(0, 11, 40), "needs", "Interview with Northwind",
             "Northwind offers Thursday 10h00 or Friday 14h30 for the interview; the reply waits for your pick.")
        line("plumber", at(0, 14, 5), "done", "The plumber's quote",
             "The plumber quoted 180 € for the leak under the sink; it is filed with the flat's papers.")
        check("landlord", ["name": "Deposit refund from the landlord", "who": "landlord", "chat": "Landlord", "since": at(-2, 18, 30)])
        check("train", ["name": "Refund for the cancelled train", "cmd": "x", "how": "the SNCF refunds page", "since": at(-4, 9, 5)])
        check("backup", ["name": "Backup done on the home server", "cmd": "x", "how": "ssh nas: the backup log", "since": at(0, 8, 0)])
        check("parcel", ["name": "Parcel from Contoso", "who": "Contoso", "since": at(-3, 16, 20)], fired: at(0, 9, 12))
        check("interview", ["name": "Interview slot from Northwind", "who": "Northwind", "since": at(-1, 10, 0)], fired: at(0, 11, 40))
        check("plumber", ["name": "Quote from the plumber", "who": "plumber", "chat": "Plumber", "since": at(-1, 19, 45)], fired: at(0, 14, 5))
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        try? "\(day.string(from: today)) 17:10:02  3 awaited, 0 arrived, 0 errors, 35 s\n"
            .write(to: state.appending(path: "check.log"), atomically: true, encoding: .utf8)
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_GB")
        clock.dateFormat = "EEE d MMM  HH:mm"
        let time = clock.string(from: Date(timeIntervalSince1970: at(0, 17, 20) / 1000))

        let inbox = Inbox(folder: folder)
        inbox.launch = { _ in false }
        inbox.refresh(force: true)

        // Sonoma.heic is square: the screen takes its middle band, as screenshot's README pictures do.
        let wall = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Sonoma.heic")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let band = CGFloat(wall.width) * size.height / size.width
        let desk = context()
        desk.interpolationQuality = .high
        desk.draw(wall.cropping(to: CGRect(x: 0, y: (CGFloat(wall.height) - band) / 2, width: CGFloat(wall.width), height: band))!, in: full)
        let sharp = desk.makeImage()!
        let ci = CIContext(options: [.workingColorSpace: NSNull()])
        func blurred(_ points: CGFloat) -> CGImage {
            let image = CIImage(cgImage: sharp).clampedToExtent().applyingGaussianBlur(sigma: Double(points * scale)).cropped(to: full)
            return ci.createCGImage(image, from: full, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        }
        // The veil's `backdrop-blur-xs`, and the glass: the wallpaper blurred 40 pt through the site's matrix, as `Glass` does.
        let soft = blurred(4)
        let glass = context()
        glass.draw(blurred(40), in: full)
        let g = glass.data!.assumingMemoryBound(to: UInt8.self)
        let bytes = Int(px.width * px.height) * 4
        let m = Glass.matrix
        for i in stride(from: 0, to: bytes, by: 4) {
            let (r, gr, b) = (Double(g[i]), Double(g[i + 1]), Double(g[i + 2]))
            for c in 0..<3 { g[i + c] = UInt8(max(0, min(255, (m[c][0] * r + m[c][1] * gr + m[c][2] * b).rounded()))) }
        }
        let fill = NSColor(Glass.filtered(.white)).usingColorSpace(.sRGB)!
        let fullFill = [fill.redComponent, fill.greenComponent, fill.blueComponent].map { Double($0) * 255 }

        func drawn(on backdrop: Color) -> CGImage {
            let renderer = ImageRenderer(content: InboxView(inbox: inbox)
                .environment(\.colorScheme, .light).environment(\.renderBackdrop, [backdrop, backdrop]))
            renderer.scale = scale
            renderer.proposedSize = ProposedViewSize(size)
            return renderer.cgImage!
        }
        /// A render's glass is a flat fill of its backdrop's colour, put under everything else of the card: drawn on black
        /// and on white, each pixel tells how much of that fill it shows, which then takes the wallpaper's own.
        func glassed(_ shots: (black: CGImage, white: CGImage), down: CGFloat) -> CGImage {
            let (b, w) = (context(), context())
            let place = full.offsetBy(dx: 0, dy: -down * scale)
            b.draw(shots.black, in: place)
            w.draw(shots.white, in: place)
            let pb = b.data!.assumingMemoryBound(to: UInt8.self), pw = w.data!.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: bytes, by: 4) where pw[i] != pb[i] || pw[i + 1] != pb[i + 1] || pw[i + 2] != pb[i + 2] {
                for c in 0..<3 {
                    let shows = (Double(pw[i + c]) - Double(pb[i + c])) / fullFill[c]
                    pb[i + c] = UInt8(max(0, min(255, (Double(pb[i + c]) + shows * Double(g[i + c])).rounded())))
                }
            }
            return b.makeImage()!
        }
        func still() -> CGImage { glassed((drawn(on: .black), drawn(on: .white)), down: 0) }

        var list = "", count = 0
        var caps: [String] = [], lit = false, caption: String?, tip: String?
        /// One still of `ticks` × 40 ms: ffmpeg reads the frames at 25 fps.
        func frame(_ ticks: Int, panel: CGImage? = nil, alpha: CGFloat = 1, down: CGFloat = 0) {
            let ctx = context()
            ctx.draw(sharp, in: full)
            if let panel {
                ctx.saveGState()
                ctx.setAlpha(alpha)
                ctx.clip(to: full.offsetBy(dx: 0, dy: -down * scale))
                ctx.draw(soft, in: full)
                ctx.restoreGState()
                ctx.setAlpha(alpha)
                ctx.draw(panel, in: full)
                ctx.setAlpha(1)
            }
            ctx.scaleBy(x: scale, y: scale)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            menuBar(inbox.items.count, time: time, tip: tip, in: ctx)
            keys(caps, lit: lit, caption)
            NSGraphicsContext.current = nil
            count += 1
            let name = String(format: "%03d.png", count)
            try? NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])?.write(to: dir.appending(path: name))
            list += "file '\(name)'\nduration \(String(format: "%.2f", Double(ticks) * 0.04))\n"
        }
        var up = false
        /// A key, lit while it is down and its button gives; then its caption.
        func press(_ code: Int, _ keys: [String], _ what: String, hold: Int) {
            _ = inbox.key(UInt16(code))
            (caps, lit, caption) = (keys, true, nil)
            frame(4, panel: up ? still() : nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            (lit, caption) = (false, what)
            frame(hold, panel: up ? still() : nil)
        }

        frame(25)
        // ⌘⌥K: `Inbox.present`, fading in while it rises into its place, in 40 ms steps.
        (caps, lit) = (["⌘", "⌥", "K"], true)
        let shots = (black: drawn(on: .black), white: drawn(on: .white))
        for k in 1...Int(Inbox.entrance / 0.04) {
            let p = CGFloat(easeOut(0.04 * Double(k) / Inbox.entrance))
            frame(1, panel: glassed(shots, down: Inbox.rise * (1 - p)), alpha: p, down: Inbox.rise * (1 - p))
        }
        up = true
        frame(3, panel: glassed(shots, down: 0))
        (lit, caption) = (false, "what came back, one line at a time")
        frame(40, panel: glassed(shots, down: 0))
        press(kVK_RightArrow, ["→"], "the next line", hold: 25)
        press(kVK_LeftArrow, ["←"], "the previous one: none is dropped", hold: 25)
        press(kVK_DownArrow, ["↓"], "asks before setting it aside", hold: 40)
        press(kVK_Return, ["↵"], "set aside as done, 2 left", hold: 40)
        press(kVK_ANSI_S, ["S"], "the watch list: still awaited, and done this week", hold: 70)
        press(kVK_ANSI_S, ["S"], "back to the lines", hold: 25)
        up = false
        press(kVK_Escape, ["esc"], "closed", hold: 20)
        (caps, caption) = ([], nil)
        frame(15)
        // The checker leaves a new line; the count picks it up, as the app's 5 s refresh does, and the loop starts on 3.
        line("deposit", at(0, 17, 10), "needs", "Deposit refund", "The landlord returns the deposit once he has your new IBAN.")
        inbox.refresh(force: true)
        tip = "a new line came back"
        frame(30)
        // The concat demuxer drops the last frame's duration unless the frame comes again.
        list += "file '\(String(format: "%03d.png", count))'\n"
        try? list.write(to: dir.appending(path: "list.txt"), atomically: true, encoding: .utf8)
        print("wrote \(count) frames and list.txt to \(dir.path)")
    }

    static func context() -> CGContext {
        CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: Int(px.width) * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// The ease-out curve `Inbox.present` animates on, at `t` of its duration.
    static func easeOut(_ t: Double) -> Double {
        let curve = CAMediaTimingFunction(name: .easeOut)
        var (a, b) = ([Float](repeating: 0, count: 2), [Float](repeating: 0, count: 2))
        curve.getControlPoint(at: 1, values: &a)
        curve.getControlPoint(at: 2, values: &b)
        func bezier(_ s: Double, _ p: Float, _ q: Float) -> Double { 3 * (1 - s) * (1 - s) * s * Double(p) + 3 * (1 - s) * s * s * Double(q) + s * s * s }
        var (lo, hi) = (0.0, 1.0)
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bezier(mid, a[0], b[0]) < t { lo = mid } else { hi = mid }
        }
        return bezier(lo, a[1], b[1])
    }

    /// A template image in white, as the menu bar draws it on a dark wallpaper; rasterized on its own first, since the
    /// badge cuts its figure out of itself.
    static func white(_ image: NSImage) -> CGImage {
        var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
        let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        let ctx = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let all = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        ctx.draw(source, in: all)
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(.white)
        ctx.fill(all)
        return ctx.makeImage()!
    }

    /// macOS's menu bar, see-through as on macOS 26: made-up menus on the left; on the right Watcher's own badge with
    /// its count, among the usual items, and `tip` under it. Above the panel, as the menu bar is above a floating window.
    static func menuBar(_ count: Int, time: String, tip: String?, in ctx: CGContext) {
        let mid = size.height - 12
        func text(_ s: String, bold: Bool = false) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: bold ? .bold : .regular),
                                                       .foregroundColor: NSColor.white])
        }
        func put(_ image: NSImage, _ x: CGFloat) {
            ctx.draw(white(image), in: CGRect(x: x, y: (mid - image.size.height / 2).rounded(), width: image.size.width, height: image.size.height))
        }
        func symbol(_ name: String) -> NSImage {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!
        }
        var x: CGFloat = 18
        let apple = symbol("apple.logo")
        put(apple, x)
        x += apple.size.width + 20
        for (i, menu) in ["Finder", "File", "Edit", "View", "Go", "Window", "Help"].enumerated() {
            let t = text(menu, bold: i == 0)
            t.draw(at: CGPoint(x: x, y: mid - t.size().height / 2))
            x += t.size().width + 20
        }
        let clock = text(time)
        var right = size.width - 16 - clock.size().width
        clock.draw(at: CGPoint(x: right, y: mid - clock.size().height / 2))
        for image in ["switch.2", "wifi", "battery.75percent"].map(symbol) + [Inbox.badge(count)] {
            right -= image.size.width + 18
            put(image, right)
        }
        if let tip {
            let t = note(tip)
            pill(t, at: CGPoint(x: min(right + 8 - (t.size().width + 32) / 2, size.width - 12 - t.size().width - 32), y: size.height - 80))
        }
    }

    static func note(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white])
    }

    /// A dark rounded label, as screenshot's README GIF has them.
    static func pill(_ text: NSAttributedString, at origin: CGPoint) {
        let r = CGRect(origin: origin, size: CGSize(width: text.size().width + 32, height: 40))
        NSColor(white: 0, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).fill()
        text.draw(at: CGPoint(x: r.minX + 16, y: r.midY - text.size().height / 2))
    }

    /// The keys just pressed as keycaps, lit while down, as in alt-tab's README; beside them what they did.
    static func keys(_ caps: [String], lit: Bool, _ caption: String?) {
        let h: CGFloat = 40, gap: CGFloat = 8, y: CGFloat = 20
        let labels = caps.map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium),
                                                        .foregroundColor: NSColor(white: 1, alpha: lit ? 1 : 0.75)])
        }
        let widths = labels.map { max(h, $0.size().width + 24) }
        let said = caption.map(note)
        let total = widths.reduce(0, +) + gap * CGFloat(max(caps.count - 1, 0)) + (said.map { $0.size().width + 32 + (caps.isEmpty ? 0 : 14) } ?? 0)
        var x = ((size.width - total) / 2).rounded()
        for (label, w) in zip(labels, widths) {
            let r = CGRect(x: x, y: y, width: w, height: h)
            (lit ? NSColor(srgbRed: 0.04, green: 0.45, blue: 0.95, alpha: 1) : NSColor(white: 0.12, alpha: 0.85)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
            label.draw(at: CGPoint(x: r.midX - label.size().width / 2, y: r.midY - label.size().height / 2))
            x += w + gap
        }
        if let said { pill(said, at: CGPoint(x: caps.isEmpty ? x : x + 14 - gap, y: y)) }
    }
}

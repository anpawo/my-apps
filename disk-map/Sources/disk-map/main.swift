import AppKit
import SwiftUI

struct DiskMapApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        Window("Disk Map", id: "main") {
            Browser(model: model)
                .navigationTitle(model.path)
                .task { model.scan() }
        }
        .defaultSize(width: 900, height: 620)
    }
}

let args = CommandLine.arguments
if args.contains("--selftest") {
    MainActor.assumeIsolated { selfCheck() }
    print("selftest ok")
    exit(0)
}
if let i = args.firstIndex(of: "--render"), args.count > i + 2 {
    MainActor.assumeIsolated {
        let model = Model(path: args[i + 1])
        model.adopt(args[i + 1])
        // ImageRenderer draws a ScrollView's lazy grid empty: host it in a window that is never ordered front.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Browser(model: model))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        host.layoutSubtreeIfNeeded()
        // cacheDisplay leaves SwiftUI's text out; the layer tree has it.
        let size = host.bounds.size, scale: CGFloat = 2
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        window.contentView!.layer!.render(in: ctx)
        try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: args[i + 2]))
    }
    exit(0)
}
DiskMapApp.main()

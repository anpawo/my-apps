import AppKit
import SwiftUI

@MainActor
enum RoadmapVisualCheck {
    private static let size = CGSize(width: 1000, height: 700)
    private static let sampleTimes: [TimeInterval] = [0, 0.07, 0.4]
    private static let redTolerance = 0.02

    static func run(_ expect: (Bool, String) -> Void) {
        for reduced in [false, true] { pages(reduced: reduced, expect) }
    }

    private static func pages(reduced: Bool, _ expect: (Bool, String) -> Void) {
        let controller = AppController()
        controller.injectSessions(RoadmapCheck.demoSessions())
        let view = FleetPages(controller: controller, previewReduceMotion: reduced) {
            Color.red.overlay(Text("FLEET MAIN").foregroundStyle(.white))
        }
        .frame(width: size.width, height: size.height)
        .background(.black)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        settle()
        guard let capture = capture(in: host) else { expect(false, "attaches the page gesture monitor to the hosting window"); return }
        expect(capture.window === window && !controller.roadmapVisible, "starts on Fleet with a window-local gesture monitor")
        capture.select(true); settle()
        capture.select(false); settle()
        for forward in [true, false] {
            let direction = forward ? "reveal" : "return"
            let mode = reduced ? "reduced motion" : "slide"
            let images = sample(host: host) { capture.select(forward) }
            let scores = images.map(red)
            let low = min(scores.first ?? 0, scores.last ?? 0)
            let high = max(scores.first ?? 0, scores.last ?? 0)
            expect(scores.count == sampleTimes.count && scores[1] > low + redTolerance && scores[1] < high - redTolerance,
                   "\(mode) \(direction) includes a visible intermediate frame")
            for (index, rep) in images.enumerated() {
                let name = "fleet-roadmap-\(reduced ? "fade" : "slide")-\(direction)-\(index).png"
                try? rep.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
            }
            expect(controller.roadmapVisible == forward, "\(mode) \(direction) ends on the requested page")
        }
        preciseEvents(capture, controller: controller, expect)
    }

    private static func preciseEvents(_ capture: RoadmapSwipeCapture.Capture, controller: AppController,
                                      _ expect: (Bool, String) -> Void) {
        func event(_ x: Int32, _ y: Int32) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
            return NSEvent(cgEvent: cg)!
        }
        expect(capture.handle(event(0, 120)) != nil && !controller.roadmapVisible, "passes vertical trackpad input to the column")
        expect(capture.handle(event(120, 0)) == nil && controller.roadmapVisible, "the native precise-scroll adapter reveals roadmaps")
        expect(capture.handle(event(-120, 0)) == nil && !controller.roadmapVisible, "the native precise-scroll adapter returns to Fleet")
    }

    private static func sample(host: NSView, change: () -> Void) -> [NSBitmapImageRep] {
        var images: [NSBitmapImageRep] = []
        let start = Date()
        for (index, time) in sampleTimes.enumerated() {
            if index == 1 { change() }
            RunLoop.main.run(until: start.addingTimeInterval(time))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                images.append(rep)
            }
        }
        return images
    }

    private static func red(_ image: NSBitmapImageRep) -> Double {
        let sampleStride = 20
        var total = 0.0, count = 0.0
        for y in stride(from: 0, to: image.pixelsHigh, by: sampleStride) {
            for x in stride(from: 0, to: image.pixelsWide, by: sampleStride) {
                if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    total += max(0, color.redComponent - color.greenComponent); count += 1
                }
            }
        }
        return total / max(1, count)
    }

    private static func capture(in view: NSView) -> RoadmapSwipeCapture.Capture? {
        if let result = view as? RoadmapSwipeCapture.Capture { return result }
        return view.subviews.lazy.compactMap { capture(in: $0) }.first
    }

    private static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(sampleTimes.last!)) }
}

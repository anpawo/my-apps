import AppKit
import SwiftUI

struct FleetPages<Main: View>: View {
    @ObservedObject var controller: AppController
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @StateObject private var roadmaps = RoadmapStore()
    var previewReduceMotion: Bool? = nil
    @ViewBuilder var main: () -> Main
    static var slideDuration: TimeInterval { 0.3 }
    static var fadeDuration: TimeInterval { 0.2 }
    private var reduceMotion: Bool { previewReduceMotion ?? systemReduceMotion }
    private var readingRoadmaps: Bool { controller.roadmapVisible && (controller.isPanelVisible || !Firestore.reads) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                main()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .offset(x: reduceMotion ? 0 : controller.roadmapVisible ? -geometry.size.width : 0)
                    .opacity(reduceMotion && controller.roadmapVisible ? 0 : 1)
                    .allowsHitTesting(!controller.roadmapVisible)
                    .accessibilityHidden(controller.roadmapVisible)
                RoadmapDashboard(store: roadmaps, sessions: controller.sessions, back: { select(false) })
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .offset(x: reduceMotion ? 0 : controller.roadmapVisible ? 0 : geometry.size.width)
                    .opacity(reduceMotion && !controller.roadmapVisible ? 0 : 1)
                    .allowsHitTesting(controller.roadmapVisible)
                    .accessibilityHidden(!controller.roadmapVisible)
            }
            .clipped()
            .background(RoadmapSwipeCapture { select($0) })
            .task(id: readingRoadmaps) {
                guard readingRoadmaps else { return }
                if CommandLine.arguments.contains("--fake") || CommandLine.arguments.contains("--check-roadmaps") {
                    roadmaps.snapshots = RoadmapCheck.demo(); return
                }
                while !Task.isCancelled {
                    await roadmaps.refresh()
                    try? await Task.sleep(for: .seconds(RoadmapStore.refreshInterval))
                }
            }
        }
    }

    private func select(_ roadmap: Bool) {
        guard roadmap != controller.roadmapVisible else { return }
        if roadmap { NSApp.keyWindow?.makeFirstResponder(nil) }
        withAnimation(.easeOut(duration: reduceMotion ? Self.fadeDuration : Self.slideDuration)) {
            controller.roadmapVisible = roadmap
        }
    }
}

struct RoadmapSwipe {
    enum Axis { case undecided, horizontal, vertical }
    private(set) var axis = Axis.undecided
    private(set) var switched = false
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    static let axisDistance: CGFloat = 8
    static let pageDistance: CGFloat = 70
    static let horizontalBias: CGFloat = 1.5

    mutating func reset() { self = Self() }

    mutating func move(x dx: CGFloat, y dy: CGFloat) -> Bool? {
        x += dx; y += dy
        if axis == .undecided, max(abs(x), abs(y)) >= Self.axisDistance {
            axis = abs(x) > abs(y) * Self.horizontalBias ? .horizontal : .vertical
        }
        guard axis == .horizontal, !switched, abs(x) >= Self.pageDistance else { return nil }
        switched = true
        return x < 0
    }
}

struct RoadmapSwipeCapture: NSViewRepresentable {
    var select: (Bool) -> Void
    func makeNSView(context: Context) -> Capture { Capture(select: select) }
    func updateNSView(_ view: Capture, context: Context) { view.select = select }

    final class Capture: NSView {
        var select: (Bool) -> Void
        private var monitor: Any?
        private var gesture = RoadmapSwipe()

        init(select: @escaping (Bool) -> Void) {
            self.select = select
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return self.handle(event)
            }
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            if event.type == .swipe {
                guard abs(event.deltaX) > abs(event.deltaY), event.deltaX != 0 else { return event }
                select(event.deltaX > 0)
                return nil
            }
            guard event.hasPreciseScrollingDeltas else { return event }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) { gesture.reset() }
            if !event.momentumPhase.isEmpty { return gesture.axis == .horizontal ? nil : event }
            let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            if let page = gesture.move(x: event.scrollingDeltaX * direction, y: event.scrollingDeltaY) { select(page) }
            let consumed = gesture.axis == .horizontal
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                // Keep the axis through momentum; the next physical gesture resets it.
                return consumed ? nil : event
            }
            return consumed ? nil : event
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

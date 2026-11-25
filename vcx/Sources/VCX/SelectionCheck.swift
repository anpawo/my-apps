import AppKit
import SwiftUI

@MainActor
enum SelectionCheck {
    private static let settleSeconds = 0.1
    private static let reply = "⟶ The VCX task bar shows every open session.\n\n- Tasks are grouped by project.\n\n✓ Done: Task bar updated."

    static func run() -> Bool {
        guard keepsSelection(progress: false), keepsSelection(progress: true) else { return false }
        print("PASS: ordinary mouse drag selects reply and progress text; unchanged refreshes preserve selection and separate paragraph bands")
        return true
    }

    private static func keepsSelection(progress: Bool) -> Bool {
        let host = NSHostingView(rootView: ProseView(text: reply).environment(\.progressNote, progress))
        host.sizingOptions = []
        let window = ComposerWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date() + settleSeconds)
        guard let field = text(in: host) else { return fail("reply text exists") }
        let range = (field.string as NSString).range(of: "VCX task bar")
        window.makeFirstResponder(field)
        drag(field, range: range)
        guard field.selectedRange() == range else { return fail("ordinary mouse drag selects reply text") }
        let boxes = (field as! BandTextView).boxes
        host.rootView = ProseView(text: reply).environment(\.progressNote, progress)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date() + settleSeconds)
        guard text(in: host) === field, field.selectedRange() == range else { return fail("selection survives an unchanged reply refresh") }
        let refreshed = (field as! BandTextView).boxes
        let sameBoxes = zip(boxes, refreshed).allSatisfy { before, after in before.color == after.color && before.rect == after.rect }
        guard refreshed.count == boxes.count, sameBoxes else { return fail("unchanged refresh preserves paragraph bands") }
        return !window.isVisible
    }

    private static func drag(_ field: NSTextView, range: NSRange) {
        let window = field.window!, manager = field.layoutManager!, container = field.textContainer!
        func point(_ index: Int) -> NSPoint {
            let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil), in: container)
            return field.convert(NSPoint(x: rect.minX + field.textContainerOrigin.x, y: rect.midY + field.textContainerOrigin.y), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = point(range.location), end = point(NSMaxRange(range))
        NSApp.postEvent(mouse(.leftMouseDragged, at: .zero), atStart: false)
        let shift = window.nextEvent(matching: .leftMouseDragged)!.locationInWindow
        let queuedEnd = NSPoint(x: end.x - shift.x, y: end.y - shift.y)
        NSApp.postEvent(mouse(.leftMouseDragged, at: queuedEnd), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, at: queuedEnd), atStart: false)
        field.mouseDown(with: mouse(.leftMouseDown, at: start))
    }

    private static func text(in view: NSView) -> NSTextView? {
        (view as? BandTextView) ?? view.subviews.lazy.compactMap { text(in: $0) }.first
    }

    private static func fail(_ message: String) -> Bool {
        fputs("FAIL: \(message)\n", stderr)
        return false
    }
}

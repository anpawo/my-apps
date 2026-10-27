import AppKit
import ScreenCaptureKit

enum Screen {
    /// 1080p-class, where Anthropic puts the balance between small text read right and image tokens: up to 2576 px
    /// are read, at a token a 28×28 patch, so 1920×1249 is some 3,000.
    static let longEdge = 1920

    static func fit(_ width: Int, _ height: Int, longEdge: Int = longEdge) -> (width: Int, height: Int) {
        let scale = min(1, Double(longEdge) / Double(max(width, height)))
        return (Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
    }

    /// The display under the mouse, this app's windows left out, as JPEG.
    @MainActor
    static func shot(longEdge: Int = longEdge) async throws -> Data {
        let screen = NSScreen.underMouse
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw Failure.noDisplay }
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []), configuration: config)
        return jpeg(image, longEdge: longEdge)
    }

    static func jpeg(_ image: CGImage, longEdge: Int = longEdge) -> Data {
        let size = fit(image.width, image.height, longEdge: longEdge)
        var out = image
        if size.width != image.width,
           let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            out = context.makeImage() ?? image
        }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
    }

    enum Failure: LocalizedError {
        case noDisplay
        var errorDescription: String? { "the display is not shareable" }
    }
}

/// The screen filmed: a frame a second, smaller than the screenshot (there are many); past `most`, every other one goes
/// and the pace halves, so a long film still sends at most `most` frames, spread over all of it.
@MainActor
final class Film {
    static let most = 16
    struct Frame { let at: TimeInterval; let jpeg: Data }
    private(set) var frames: [Frame] = []
    private var every: TimeInterval = 1
    private var task: Task<Void, Never>?

    func start() {
        let began = Date()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let shot = try? await Screen.shot(longEdge: 1280)
                guard let self, !Task.isCancelled else { return }
                if let shot { add(Frame(at: Date().timeIntervalSince(began), jpeg: shot)) }
                try? await Task.sleep(for: .seconds(every))
            }
        }
    }

    func stop() { task?.cancel() }

    func add(_ frame: Frame) {
        frames.append(frame)
        guard frames.count > Self.most else { return }
        frames = frames.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        every *= 2
    }

    /// What goes with the frames, after them: how long the film ran and when each frame was taken.
    static func words(_ frames: [Frame], length: TimeInterval) -> String {
        "The screen, filmed for \(Sound.clock(length)): the \(frames.count) images above, oldest first, taken at "
            + frames.map { Sound.clock($0.at) }.joined(separator: ", ") + "."
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID }

    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(p) } ?? main ?? screens[0]
    }
}

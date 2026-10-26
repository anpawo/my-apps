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
    static func shot() async throws -> Data {
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
        return jpeg(image)
    }

    static func jpeg(_ image: CGImage) -> Data {
        let size = fit(image.width, image.height)
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

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID }

    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(p) } ?? main ?? screens[0]
    }
}

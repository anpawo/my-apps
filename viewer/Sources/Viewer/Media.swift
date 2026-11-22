import AppKit
import AVKit
import PDFKit
import ViewerCore

/// What the right side shows. Each call returns the HUD text, if any.
@MainActor
protocol Media: AnyObject {
    var view: NSView { get }
    func changeSpeed(by steps: Int) -> String?
    func togglePlay()
    func seek(by seconds: Double)
    func jump(toEnd: Bool)
    func setVolume(_ volume: Float)
    func zoom(in: Bool)
    func fit()
    func stop()
}

extension Media {
    func changeSpeed(by steps: Int) -> String? { nil }
    func togglePlay() {}
    func seek(by seconds: Double) {}
    func jump(toEnd: Bool) {}
    func setVolume(_ volume: Float) {}
    func zoom(in: Bool) {}
    func fit() {}
    func stop() {}
}

@MainActor
func makeMedia(_ url: URL, kind: Kind, volume: Float) -> Media {
    switch kind {
    case .image: ImageMedia(url)
    case .gif: GIFMedia(url)
    case .video: VideoMedia(url, volume: volume)
    case .pdf: PDFMedia(url)
    }
}

@MainActor
private func centeredLabel(_ text: String, in view: NSView) {
    let label = NSTextField(labelWithString: text)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    label.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
    label.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
}

/// Keeps a document smaller than the view in its middle instead of the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView?.frame else { return rect }
        if rect.width > doc.width { rect.origin.x = (doc.width - rect.width) / 2 }
        if rect.height > doc.height { rect.origin.y = (doc.height - rect.height) / 2 }
        return rect
    }
}

@MainActor final class ImageMedia: Media {
    private static let zoomStep: CGFloat = 1.25
    private let scroll = NSScrollView()
    private let imageView = NSImageView()
    var view: NSView { scroll }

    init(_ url: URL) {
        let image = NSImage(contentsOf: url)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
        scroll.contentView = CenteringClipView()
        scroll.documentView = imageView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 32
        if image == nil { centeredLabel("Cannot open this image", in: scroll) }
    }

    /// Whole image in view, never enlarged past its own size.
    func fit() {
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0 else { return }
        scroll.magnification = min(scroll.bounds.width / size.width, scroll.bounds.height / size.height, 1)
    }

    func zoom(in zoomIn: Bool) {
        scroll.magnification *= zoomIn ? Self.zoomStep : 1 / Self.zoomStep
    }
}

@MainActor final class PDFMedia: Media {
    private let pdf = PDFView()
    var view: NSView { pdf }

    init(_ url: URL) {
        pdf.document = PDFDocument(url: url)
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        if pdf.document == nil { centeredLabel("Cannot open this PDF", in: pdf) }
    }

    func changeSpeed(by steps: Int) -> String? {
        steps > 0 ? pdf.goToNextPage(nil) : pdf.goToPreviousPage(nil)
        guard let doc = pdf.document, let page = pdf.currentPage else { return nil }
        return "Page \(doc.index(for: page) + 1) of \(doc.pageCount)"
    }

    func zoom(in zoomIn: Bool) { zoomIn ? pdf.zoomIn(nil) : pdf.zoomOut(nil) }
}

@MainActor final class VideoMedia: Media {
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    private var speed = 1.0
    var view: NSView { playerView }

    init(_ url: URL, volume: Float) {
        player = AVPlayer(url: url)
        player.volume = volume
        playerView.player = player
        playerView.controlsStyle = .floating
        player.play()
    }

    func changeSpeed(by steps: Int) -> String? {
        speed = Speed.step(speed, by: steps)
        player.defaultRate = Float(speed)
        if player.rate != 0 { player.rate = Float(speed) }
        return Speed.label(speed)
    }

    func togglePlay() {
        guard player.rate == 0 else { return player.pause() }
        if let end = duration, player.currentTime().seconds >= end { player.seek(to: .zero) }
        player.play()
    }

    func seek(by seconds: Double) {
        let target = max(player.currentTime().seconds + seconds, 0)
        seek(to: min(target, duration ?? target))
    }

    func jump(toEnd: Bool) { seek(to: toEnd ? duration ?? 0 : 0) }
    func setVolume(_ volume: Float) { player.volume = volume }
    func stop() { player.pause() }

    private var duration: Double? {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite else { return nil }
        return seconds
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// Frames decoded up front and played on our own timer, so the speed can change (NSImageView's
/// own GIF animation has no rate).
@MainActor final class GIFMedia: Media {
    private let imageView = NSImageView()
    private var frames: [CGImage] = []
    private var durations: [Double] = []
    private var index = 0
    private var speed = 1.0
    private var playing = true
    private var timer: Timer?
    var view: NSView { imageView }

    init(_ url: URL) {
        // ponytail: every frame held in memory; decode on the fly if huge GIFs ever matter.
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            for i in 0..<CGImageSourceGetCount(source) {
                guard let frame = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                frames.append(frame)
                durations.append(Timeline.delay((gif?[kCGImagePropertyGIFUnclampedDelayTime]
                    ?? gif?[kCGImagePropertyGIFDelayTime]) as? Double))
            }
        }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        if frames.isEmpty { centeredLabel("Cannot open this GIF", in: imageView) }
        show(0)
    }

    func changeSpeed(by steps: Int) -> String? {
        speed = Speed.step(speed, by: steps)
        schedule()
        return Speed.label(speed)
    }

    func togglePlay() {
        playing.toggle()
        schedule()
    }

    func seek(by seconds: Double) {
        let total = durations.reduce(0, +)
        let target = min(max(Timeline.start(of: index, durations: durations) + seconds, 0), total)
        show(Timeline.frame(at: target, durations: durations))
    }

    func jump(toEnd: Bool) { show(toEnd ? frames.count - 1 : 0) }
    func stop() { timer?.invalidate() }

    private func show(_ frame: Int) {
        guard frames.indices.contains(frame) else { return }
        index = frame
        let image = frames[frame]
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        guard playing, frames.count > 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: durations[index] / speed, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.show((self.index + 1) % self.frames.count)
            }
        }
    }
}

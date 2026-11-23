import AppKit
import AVKit
import PDFKit
import ViewerCore

/// What the right side shows. Each call returns the HUD text, if any.
@MainActor
protocol Media: AnyObject {
    var view: NSView { get }
    var isPlaying: Bool { get }
    /// Seconds played and the whole length, for the playback bar.
    var progress: (current: Double, total: Double)? { get }
    func seek(to seconds: Double)
    func changeSpeed(by steps: Int) -> String?
    func togglePlay()
    func seek(by seconds: Double)
    func jump(toEnd: Bool)
    func setVolume(_ volume: Float)
    func zoom(in: Bool)
    func fit()
    func stop()
    /// Its width over its height, nil when it has no picture (music, PDF); a video's comes later.
    func loadAspect(_ done: @escaping (CGFloat?) -> Void)
}

extension Media {
    var isPlaying: Bool { false }
    var progress: (current: Double, total: Double)? { nil }
    func seek(to seconds: Double) {}
    func changeSpeed(by steps: Int) -> String? { nil }
    func togglePlay() {}
    func seek(by seconds: Double) {}
    func jump(toEnd: Bool) {}
    func setVolume(_ volume: Float) {}
    func zoom(in: Bool) {}
    func fit() {}
    func stop() {}
    func loadAspect(_ done: @escaping (CGFloat?) -> Void) { done(nil) }
}

@MainActor
func makeMedia(_ url: URL, kind: Kind, volume: Float, onPlayingChange: @escaping () -> Void) -> Media {
    switch kind {
    case .image: ImageMedia(url)
    case .gif: GIFMedia(url)
    case .video, .music: VideoMedia(url, volume: volume, onPlayingChange: onPlayingChange)
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

private func aspect(of size: NSSize) -> CGFloat? {
    size.width > 0 && size.height > 0 ? size.width / size.height : nil
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

    func loadAspect(_ done: @escaping (CGFloat?) -> Void) { done(aspect(of: imageView.frame.size)) }
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
    private var rateObservation: NSKeyValueObservation?
    var view: NSView { playerView }
    var isPlaying: Bool { player.rate != 0 }

    init(_ url: URL, volume: Float, onPlayingChange: @escaping () -> Void) {
        player = AVPlayer(url: url)
        rateObservation = player.observe(\.rate) { _, _ in DispatchQueue.main.async(execute: onPlayingChange) }
        player.volume = volume
        playerView.player = player
        playerView.controlsStyle = .none
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

    var progress: (current: Double, total: Double)? {
        duration.map { (player.currentTime().seconds, $0) }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func loadAspect(_ done: @escaping (CGFloat?) -> Void) {
        guard let asset = player.currentItem?.asset else { return done(nil) }
        Task { @MainActor in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return done(nil) }
            // A phone's portrait video is stored landscape and turned by its transform.
            let shown = size.applying(transform)
            done(aspect(of: NSSize(width: abs(shown.width), height: abs(shown.height))))
        }
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
    var isPlaying: Bool { playing && frames.count > 1 }

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

    func loadAspect(_ done: @escaping (CGFloat?) -> Void) {
        done(frames.first.flatMap { aspect(of: NSSize(width: $0.width, height: $0.height)) })
    }
    func stop() { timer?.invalidate() }

    var progress: (current: Double, total: Double)? {
        frames.count > 1 ? (Timeline.start(of: index, durations: durations), durations.reduce(0, +)) : nil
    }

    func seek(to seconds: Double) { show(Timeline.frame(at: seconds, durations: durations)) }

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

/// The details on each row's second line, made off the main thread.
@MainActor enum Thumbnails {
    static func details(of entry: Entry, done: @escaping @MainActor (String) -> Void) {
        let url = entry.url, kind = entry.kind
        if kind == .video || kind == .music {
            Task { @MainActor in
                guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.seconds.isFinite else { return }
                done(Details.duration(duration.seconds))
            }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let text = stillDetails(url, kind: kind)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(text) } }
        }
    }

    private nonisolated static func stillDetails(_ url: URL, kind: Kind) -> String {
        if kind == .pdf { return CGPDFDocument(url as CFURL).map { Details.pages($0.numberOfPages) } ?? "" }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "" }
        if kind == .gif {
            let delays = (0..<CGImageSourceGetCount(source)).map { i -> Double in
                let gif = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary]
                    as? [CFString: Any]
                return Timeline.delay((gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]) as? Double)
            }
            return Details.duration(delays.reduce(0, +))
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
              let height = properties?[kCGImagePropertyPixelHeight] as? Int else { return "" }
        return Details.pixels(width, height)
    }
}

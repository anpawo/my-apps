import AppKit
import ViewerCore

/// Dates in English, in the order and clock of the Mac's region.
let englishInRegion = Locale(languageCode: .english, languageRegion: Locale.current.region)

private func label(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingMiddle
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
}

// MARK: Viewer

/// The file shown, under its modified date, with the playback bar over its bottom when it plays.
@MainActor final class ViewerPane: NSViewController {
    private static let controlsMargin: CGFloat = 16
    let hud = HUD()
    let controls = Controls()
    /// Esc hides the bar for every file until pressed again.
    var controlsHidden = false { didSet { showControls() } }
    private let empty = label("Drop images, videos, GIFs, music, PDFs or text files", size: 18, color: .secondaryLabelColor)
    private let stage = NSView()
    var stageSize: NSSize { stage.frame.size }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: initialWindowSize))
        for view in [stage, hud, controls] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in [stage, empty, hud, controls] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            hud.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hud.topAnchor.constraint(equalTo: stage.topAnchor, constant: 16),
            controls.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -Self.controlsMargin),
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: stage.leadingAnchor, constant: Self.controlsMargin),
        ])
        controls.isHidden = true
        view = root
    }

    func show(_ media: Media?, plays: Bool) {
        stage.subviews.forEach { $0.removeFromSuperview() }
        empty.isHidden = media != nil
        controls.media = plays ? media : nil
        showControls()
        guard let media else { return }
        view.layoutSubtreeIfNeeded()
        media.view.frame = stage.bounds
        media.view.autoresizingMask = [.width, .height]
        stage.addSubview(media.view)
        media.fit()
    }

    private func showControls() { controls.isHidden = controlsHidden || controls.media == nil }
}

/// QuickTime's layout: the volume on the left, slower, play or pause and faster centred, the speed on the right, then the
/// time on either side of the slider to seek, in a dark rounded box. The speed keeps one width, so a new
/// speed moves nothing.
@MainActor final class Controls: NSVisualEffectView {
    private static let refreshInterval = 0.25
    private static let width: CGFloat = 520
    private static let height: CGFloat = 72
    private static let cornerRadius: CGFloat = 18
    private static let padding: CGFloat = 14
    private static let rowInset: CGFloat = 12
    /// The widest label `Speed.steps` makes.
    private static let widestSpeed = "0.25×"
    private static let volumeSliderWidth: CGFloat = 72
    var perform: (Action) -> Void = { _ in }
    var setVolume: (Float) -> Void = { _ in }
    weak var media: Media? { didSet { refresh() } }
    private lazy var playButton = button("play.fill", .playPause)
    private lazy var muteButton = button("speaker.wave.3.fill", .mute)
    private let volume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let speed = NSTextField(labelWithString: Speed.label(1))
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var timer: Timer?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        for field in [speed, elapsed, total] {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            field.textColor = .white
        }
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(seek)
        volume.controlSize = .small
        volume.target = self
        volume.action = #selector(volumeMoved)
        speed.alignment = .right
        let speedWidth = (Self.widestSpeed as NSString).size(withAttributes: [.font: speed.font!]).width
        let transport = NSStackView(views: [button("backward.fill", .slower), playButton, button("forward.fill", .faster)])
        transport.spacing = 18
        let time = NSStackView(views: [elapsed, slider, total])
        time.spacing = 10
        let sound = NSStackView(views: [muteButton, volume])
        sound.spacing = 6
        for view in [sound, transport, time, speed] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Under the window's own size: a portrait video's narrow window squeezes the bar, never widens.
            widthAnchor.constraint(equalToConstant: Self.width).withPriority(.defaultLow),
            heightAnchor.constraint(equalToConstant: Self.height),
            transport.centerXAnchor.constraint(equalTo: centerXAnchor),
            transport.topAnchor.constraint(equalTo: topAnchor, constant: Self.rowInset),
            sound.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            sound.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            volume.widthAnchor.constraint(equalToConstant: Self.volumeSliderWidth),
            speed.widthAnchor.constraint(equalToConstant: ceil(speedWidth)),
            speed.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding - 4),
            speed.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            time.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.rowInset),
            time.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
        ])
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(playing: Bool, speed label: String, volume level: Float) {
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        speed.stringValue = label
        muteButton.image = NSImage(systemSymbolName: volumeSymbol(level), accessibilityDescription: nil)
        if NSEvent.pressedMouseButtons == 0 { volume.floatValue = level }
    }

    private func refresh() {
        guard !isHidden, let progress = media?.progress else { return }
        elapsed.stringValue = Details.duration(progress.current)
        total.stringValue = Details.duration(progress.total)
        // A drag in progress owns the knob.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        slider.maxValue = max(progress.total, 0.01)
        slider.doubleValue = progress.current
    }

    private func button(_ symbol: String, _ action: Action) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                              target: self, action: #selector(clicked(_:)))
        button.isBordered = false
        button.contentTintColor = .white
        button.tag = actions.count
        actions.append(action)
        return button
    }

    private var actions: [Action] = []
    @objc private func clicked(_ sender: NSButton) { perform(actions[sender.tag]) }
    @objc private func seek() { media?.seek(to: slider.doubleValue) }
    @objc private func volumeMoved() { setVolume(volume.floatValue) }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}


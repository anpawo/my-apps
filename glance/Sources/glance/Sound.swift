import AVFoundation
import NaturalLanguage
import ScreenCaptureKit
import Speech

/// The computer's sound while it runs (calls, videos, music: every app but glance), 16 kHz mono, handed on as it comes.
/// It rides on Screen Recording, the permission the screenshot already has. Never kept.
final class Listener: NSObject, SCStreamOutput, @unchecked Sendable {
    static let rate = 16_000
    static let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!

    /// Called on `queue`, a piece at a time.
    private let hear: (AVAudioPCMBuffer) -> Void
    private let queue = DispatchQueue(label: "com.mr.glance.listener")
    /// On the main thread.
    private var stream: SCStream?
    private var stopped = false

    init(hear: @escaping (AVAudioPCMBuffer) -> Void) { self.hear = hear }

    @MainActor
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw Screen.Failure.noDisplay }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Self.rate
        config.channelCount = 1
        // A stream always has a picture: the smallest, once a second.
        (config.width, config.height) = (2, 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Taken and dropped: without a screen output SCStream logs every frame it has nowhere to send.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        // `stop` came while it was starting.
        if stopped { try? await stream.stopCapture() }
    }

    @MainActor
    func stop() async {
        stopped = true
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid else { return }
        // Float32, one buffer a channel: one channel was asked for.
        try? buffer.withAudioBufferList { list, _ in
            guard let b = list.first, let data = b.mData else { return }
            let count = AVAudioFrameCount(Int(b.mDataByteSize) / MemoryLayout<Float>.size)
            guard count > 0, let piece = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: count) else { return }
            piece.frameLength = count
            memcpy(piece.floatChannelData![0], data, Int(b.mDataByteSize))
            hear(piece)
        }
    }
}

/// What the computer says, in words as it says it, on the Mac: Apple's speech recognizer runs once per language of
/// his (French and English), and each sentence keeps the surer of the two. Measured 27/10/2026 on an M4: a word shows
/// about a second after it is said; the right language reads 0.94 sure, the wrong one 0.18 to 0.73.
final class Transcript: @unchecked Sendable {
    struct Heard: Equatable {
        var language: String
        var start: Double
        var end: Double
        var text: String
        var confidence: Double
    }

    /// Called on the main thread with the whole text so far, at each change.
    var onChange: @MainActor (String) -> Void = { _ in }
    /// The rest on the main thread; `converter` and `inputs` on the listener's queue once started. Sentences by language,
    /// settled and still being heard.
    private var finals: [String: [Heard]] = [:]
    private var pending: [String: [Heard]] = [:]
    private var analyzers: [SpeechAnalyzer] = []
    private var readers: [Task<Void, Never>] = []
    private var inputs: [AsyncStream<AnalyzerInput>.Continuation] = []
    private var converter: AVAudioConverter?

    @MainActor
    var text: String { Self.shown(finals: Array(finals.values.joined()), pending: Array(pending.values)) }

    /// The whole sentences, settled or not, each in the language surer of it; then the one being said, from the language
    /// whose take reads best among those that do not go back over what is shown. Words still being heard are one piece
    /// since the last pause, with one time: run from French into English, the English take's piece starts with its
    /// garbled French and would replace the French shown (measured 27/10/2026).
    static func shown(finals: [Heard], pending: [[Heard]]) -> String {
        var whole = finals, open: [Heard] = []
        for said in pending {
            if let last = said.last, let mark = last.text.last, !".?!…".contains(mark) {
                whole += said.dropLast()
                open.append(last)
            } else {
                whole += said
            }
        }
        let covered = whole.map(\.end).max() ?? -.infinity
        let tail = open.filter { covered - $0.start <= 0.5 * ($0.end - $0.start) }.max { $0.confidence < $1.confidence }
        return (merge(whole) + (tail.map { [$0.text] } ?? [])).joined(separator: " ")
    }

    /// His languages, as the recognizer has them: English and French here.
    static func languages() async -> [Locale] {
        let supported = await SpeechTranscriber.supportedLocales
        var out: [Locale] = []
        for id in Locale.preferredLanguages {
            // French on a US Mac ("fr-US") has no model of its own, and the recognizer's nearest is drawn at random among
            // France, Switzerland, Belgium and Canada (measured 27/10/2026): the language's home country instead.
            let asked = Locale.Language(identifier: id), code = asked.languageCode
            let home = Locale.Language(identifier: Locale.Language(identifier: code?.identifier ?? id).maximalIdentifier).region
            func model(_ region: Locale.Region?) -> Locale? { supported.first { $0.language.languageCode == code && $0.region == region } }
            var l = model(asked.region) ?? model(home)
            if l == nil { l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) }
            if let l, !out.contains(l) { out.append(l) }
        }
        return out.isEmpty ? [Locale(identifier: "en_US")] : Array(out.prefix(2))
    }

    /// Downloads a language's model the first time (about a second), then starts listening for words.
    @MainActor
    func start() async throws {
        var format: AVAudioFormat?
        for locale in await Self.languages() {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                                           attributeOptions: [.transcriptionConfidence, .audioTimeRange])
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await install.downloadAndInstall() }
            if format == nil { format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) }
            let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [module])
            try await analyzer.start(inputSequence: stream)
            let language = locale.identifier
            readers.append(Task { @MainActor in
                do {
                    for try await r in module.results { self.take(r, language: language) }
                } catch {}
            })
            analyzers.append(analyzer)
            inputs.append(input)
        }
        guard let format, let converter = AVAudioConverter(from: Listener.format, to: format) else { throw Failure.noFormat }
        self.converter = converter
    }

    /// On the listener's queue: the piece, as the recognizer reads sound (16-bit), to every language.
    func feed(_ piece: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(Double(piece.frameLength) * ratio) + 32)
        else { return }
        var given = false
        converter.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return piece
        }
        guard out.frameLength > 0 else { return }
        for input in inputs { input.yield(AnalyzerInput(buffer: out)) }
    }

    /// The text once every language has said its last word.
    @MainActor
    func finish() async -> String {
        inputs.forEach { $0.finish() }
        for analyzer in analyzers { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        for reader in readers { await reader.value }
        return text
    }

    @MainActor
    private func take(_ r: SpeechTranscriber.Result, language: String) {
        let said = Self.sentences(r.text, language: language, within: r.range)
        if r.isFinal {
            pending[language] = nil
            finals[language, default: []] += said
        } else {
            pending[language] = said
        }
        onChange(text)
    }

    /// A result cut at its sentence ends, each with its time and how sure the recognizer is of it: a result can run
    /// from French into English with no pause between. Words still being heard come as one piece with one time, no
    /// confidence: each sentence takes its share of the time by length, and how much it reads as its language stands in
    /// for the confidence, as the wrong language writes the other's sounds in its own words ("Situ a pure regardé" for
    /// "Si tu as pu regarder").
    static func sentences(_ text: AttributedString, language: String, within range: CMTimeRange) -> [Heard] {
        var out: [Heard] = [], words = "", start: Double?, end = range.start.seconds, sure = 0.0, chars = 0.0
        func close() {
            let said = words.trimmingCharacters(in: .whitespaces)
            if !said.isEmpty {
                out.append(Heard(language: language, start: start ?? end, end: end, text: said,
                                 confidence: chars > 0 ? sure / chars : reads(said, as: language)))
            }
            (words, start, sure, chars) = ("", nil, 0, 0)
        }
        for run in text.runs {
            let piece = String(text[run.range].characters)
            var part = "", done = 0
            for (i, c) in zip(piece.indices, piece) {
                part.append(c)
                let ends = ".?!…".contains(c) && (piece.index(after: i) == piece.endIndex || piece[piece.index(after: i)].isWhitespace)
                guard ends || piece.index(after: i) == piece.endIndex else { continue }
                words += part
                if let time = run.audioTimeRange {
                    let a = time.start.seconds, b = time.end.seconds
                    start = start ?? a + (b - a) * Double(done) / Double(piece.count)
                    done += part.count
                    end = a + (b - a) * Double(done) / Double(piece.count)
                }
                if let c = run.transcriptionConfidence {
                    sure += c * Double(part.count)
                    chars += Double(part.count)
                }
                part = ""
                if ends { close() }
            }
        }
        if start == nil { end = range.end.seconds }
        close()
        return out
    }

    static func reads(_ text: String, as language: String) -> Double {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let code = Locale(identifier: language).language.languageCode?.identifier ?? language
        return recognizer.languageHypotheses(withMaximum: 10)[NLLanguage(rawValue: code)] ?? 0
    }

    /// Both languages hear the same sound: sentences that overlap are one stretch, said in the language surer of it.
    /// Overlapping by less than half the shorter one, they are apart: the languages do not end a sentence on the same
    /// instant (half a second between them, measured).
    static func merge(_ finals: [Heard]) -> [String] {
        var out: [String] = [], stretch: [Heard] = []
        func close() {
            func sure(_ hs: [Heard]) -> Double {
                hs.map { $0.confidence * Double($0.text.count) }.reduce(0, +) / max(1, Double(hs.map(\.text.count).reduce(0, +)))
            }
            if let best = Dictionary(grouping: stretch, by: \.language).values.max(by: { sure($0) < sure($1) }) { out += best.map(\.text) }
            stretch = []
        }
        for h in finals.sorted(by: { $0.start < $1.start }) {
            if let last = stretch.max(by: { $0.end < $1.end }),
               last.end - h.start <= 0.5 * min(last.end - last.start, h.end - h.start) { close() }
            stretch.append(h)
        }
        close()
        return out
    }

    enum Failure: LocalizedError {
        case noFormat
        var errorDescription: String? { "the speech recognizer takes no sound format glance can give it" }
    }
}

enum Sound {
    /// The paragraph that goes before the question.
    static func words(_ text: String, length: TimeInterval) -> String {
        let head = "Sound from the computer, \(clock(length))"
        return text.isEmpty ? head + ": no speech in it." : head + ", transcribed:\n" + text
    }

    static func clock(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}

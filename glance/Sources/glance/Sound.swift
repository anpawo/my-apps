import AVFoundation
import ScreenCaptureKit

/// The computer's sound while it runs (calls, videos, music: every app but glance), as Whisper reads it: 16 kHz mono.
/// It rides on Screen Recording, the permission the screenshot already has. Kept in memory only.
final class Listener: NSObject, SCStreamOutput, @unchecked Sendable {
    static let rate = 16_000

    /// `samples` is only touched on it; `stream` and `stopped` on the main thread.
    private let queue = DispatchQueue(label: "com.mr.glance.listener")
    private var samples: [Float] = []
    private var stream: SCStream?
    private var stopped = false

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

    /// What it heard so far; it hears nothing more.
    @MainActor
    func stop() async -> [Float] {
        stopped = true
        try? await stream?.stopCapture()
        stream = nil
        return queue.sync { samples }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid else { return }
        // Float32, one buffer a channel: one channel was asked for.
        try? buffer.withAudioBufferList { list, _ in
            guard let b = list.first, let data = b.mData else { return }
            samples.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                                           count: Int(b.mDataByteSize) / MemoryLayout<Float>.size))
        }
    }
}

/// What was heard, put in words on the Mac by whisper.cpp: no audio leaves it, only the transcript, with the question.
enum Sound {
    static let whisper = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        .first(where: FileManager.default.isExecutableFile(atPath:))
    static let models = "\(NSHomeDirectory())/.local/share/whisper"
    /// Turbo: 2 min of speech in 8.5 s on battery, where large-v3 took 16 s; and it kept a French then English clip as
    /// it was said, where large-v3 put it all in English and small dropped the English (measured 27/10/2026).
    static let model = "\(models)/ggml-large-v3-turbo-q5_0.bin"
    /// Silero voice detection: Whisper hears no "Thank you." in silence, and skips it.
    static let vad = "\(models)/ggml-silero-v5.1.2.bin"

    /// The paragraph that goes before the question.
    static func words(_ samples: [Float], length: TimeInterval) async -> String {
        let head = "Sound from the computer, \(clock(length))"
        if samples.allSatisfy({ abs($0) < 0.001 }) { return head + ": silence, nothing played." }
        do {
            let text = try await transcribe(samples)
            return text.isEmpty ? head + ": no speech in it." : head + ", transcribed:\n" + text
        } catch {
            return head + ": not transcribed, \(error.localizedDescription)."
        }
    }

    static func clock(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    static func transcribe(_ samples: [Float]) async throws -> String {
        guard let whisper, FileManager.default.fileExists(atPath: model), FileManager.default.fileExists(atPath: vad)
        else { throw Failure.noWhisper }
        // whisper-cli reads files only; this one lives as long as it takes.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("glance-\(UUID().uuidString).wav")
        try wav(samples).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await Task.detached {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: whisper)
            p.arguments = ["-m", model, "-f", file.path, "-l", "auto", "--vad", "-vm", vad, "-np", "-nt"]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw Failure.whisperFailed(p.terminationStatus) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    /// 16-bit PCM, mono, at `Listener.rate`.
    static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        d.append(contentsOf: "RIFF".utf8); put(UInt32(36 + bytes)); d.append(contentsOf: "WAVEfmt ".utf8)
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(Listener.rate)); put(UInt32(Listener.rate * 2))
        put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: "data".utf8); put(UInt32(bytes))
        samples.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    enum Failure: LocalizedError {
        case noWhisper
        case whisperFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .noWhisper: "whisper-cli or its models are missing (brew install whisper-cpp; models in ~/.local/share/whisper)"
            case .whisperFailed(let status): "whisper-cli failed (\(status))"
            }
        }
    }
}

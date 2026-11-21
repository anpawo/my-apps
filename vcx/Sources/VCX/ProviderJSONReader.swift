import Foundation
import Darwin

final class ProviderJSONReader: @unchecked Sendable {
    static let maximumMessages = 256
    static let maximumBytes = 64 * 1024 * 1024
    private let handle: FileHandle
    private let fd: Int32
    private let receive: (JSON) -> Void
    private let invalid: (String) -> Void
    private let disconnected: () -> Void
    private let queue = DispatchQueue(label: "vcx.provider.reader")
    private var source: DispatchSourceRead?
    private var input = Data()
    private var searchOffset = 0
    private var readyEnd: Data.Index?
    private var messages = 0
    private var bytes = 0
    private var paused = false
    private var closed = false

    init(handle: FileHandle, leftover: Data = Data(), receive: @escaping (JSON) -> Void, invalid: @escaping (String) -> Void = { _ in }, disconnected: @escaping () -> Void) throws {
        self.handle = handle; fd = handle.fileDescriptor; input = leftover
        self.receive = receive; self.invalid = invalid; self.disconnected = disconnected
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw CXError(message: "Cannot configure provider output reader.") }
    }

    var queuedMessages: Int { queue.sync { messages } }
    var queuedBytes: Int { queue.sync { bytes } }

    func start() {
        queue.sync {
            guard source == nil, !closed else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read() }
            let handle = handle
            source.setCancelHandler { try? handle.close() }
            self.source = source; source.resume()
            if !input.isEmpty { read() }
        }
    }

    var descriptor: Int32 { fd }

    // A live update stops reading between lines; nil while parsed lines are still queued for the main actor.
    // It reuses the backpressure pause, so close and deinit resume the source before cancelling it.
    func freeze() -> Data? {
        queue.sync {
            guard source != nil, !closed, !paused, messages == 0 else { return nil }
            paused = true; source?.suspend()
            return input
        }
    }

    func thaw() {
        queue.sync {
            guard paused, !closed, messages == 0 else { return }
            paused = false; source?.resume(); read()
        }
    }

    func close() { queue.sync { finish(notify: false) } }

    private func drain() -> Bool {
        while !closed {
            guard let end = readyEnd ?? input[input.index(input.startIndex, offsetBy: searchOffset)...].firstIndex(of: 10) else {
                searchOffset = input.count
                if input.count > RuntimeChannel.maximumFrame { finish(error: "Provider output exceeded the frame limit.") }
                return !closed
            }
            let size = input.distance(from: input.startIndex, to: end)
            guard size <= RuntimeChannel.maximumFrame else { finish(error: "Provider output exceeded the frame limit."); return false }
            guard messages < Self.maximumMessages, bytes + size <= Self.maximumBytes else {
                readyEnd = end; paused = true; source?.suspend(); return false
            }
            let line = Data(input[..<end])
            input.removeSubrange(...end); readyEnd = nil; searchOffset = 0
            messages += 1; bytes += size
            var message: JSON?, malformed = false
            do { message = try JSONSerialization.jsonObject(with: line) as? JSON } catch { malformed = true }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let message { self.receive(message) }
                else if malformed { self.invalid("Provider sent invalid JSON.") }
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.messages -= 1; self.bytes -= size
                    if self.paused, !self.closed {
                        self.paused = false; self.source?.resume(); self.read()
                    }
                }
            }
        }
        return false
    }

    private func read() {
        guard !closed, !paused, drain() else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<16 {
            let length = Darwin.read(fd, &buffer, buffer.count)
            if length == 0 { finish(); return }
            if length < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { finish(error: "Provider output could not be read.") }
                return
            }
            input.append(contentsOf: buffer.prefix(length))
            guard drain() else { return }
        }
    }

    private func finish(error: String? = nil, notify: Bool = true) {
        guard !closed else { return }
        closed = true
        if paused { paused = false; source?.resume() }
        if let source { source.cancel(); self.source = nil }
        else { try? handle.close() }
        input.removeAll(); readyEnd = nil
        if notify {
            DispatchQueue.main.async { [self] in
                if let error { invalid(error) }
                disconnected()
            }
        }
    }

    deinit {
        if paused { source?.resume() }
        if let source { source.cancel() }
        else if !closed { try? handle.close() }
    }
}

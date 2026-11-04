import Darwin
import Foundation

private func runtimeAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CXError(message: "Runtime socket path is too long.") }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}

private func runtimeDescriptor(_ fd: Int32) throws {
    guard fd >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw CXError(message: "Cannot configure runtime socket.") }
    var enabled: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else { throw CXError(message: "Cannot configure runtime socket.") }
}

private func runtimePeer(_ fd: Int32) -> Bool {
    var user: uid_t = 0, group: gid_t = 0
    return getpeereid(fd, &user, &group) == 0 && user == geteuid()
}

final class RuntimeChannel: @unchecked Sendable {
    static let maximumFrame = 32 * 1024 * 1024
    static let maximumBuffered = 64 * 1024 * 1024
    let id = UUID()
    var onMessage: (JSON) -> Void = { _ in }
    var onClose: () -> Void = {}
    private let fd: Int32
    private let queue = DispatchQueue(label: "vcx.runtime.channel")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var input = Data()
    private var output: [Data] = []
    private var outputIndex = 0
    private var outputOffset = 0
    private var outputBytes = 0
    private var deliveryBytes = 0
    private var deliveryMessages = 0
    private var readPaused = false
    private var closed = false

    fileprivate init(fd: Int32) {
        self.fd = fd
        queue.setSpecific(key: queueKey, value: true)
    }

    static func connect(path: String) throws -> RuntimeChannel {
        var info = stat()
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(parent, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else { throw CXError(message: "Runtime directory must be private and owned by this user.") }
        guard lstat(path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o077 == 0 else { throw CXError(message: "Runtime socket is unavailable or has unsafe ownership.") }
        var address = try runtimeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CXError(message: "Cannot create runtime socket.") }
        do {
            try runtimeDescriptor(fd)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw CXError(message: "Cannot connect to runtime.") }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&descriptor, 1, 2_000) > 0 else { throw CXError(message: "Runtime connection timed out.") }
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw CXError(message: "Cannot connect to runtime.") }
            }
            guard runtimePeer(fd) else { throw CXError(message: "Runtime peer belongs to another user.") }
            return RuntimeChannel(fd: fd)
        } catch { Darwin.close(fd); throw error }
    }

    func start() {
        synchronized {
            guard !closed, readSource == nil else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read() }
            let descriptor = fd
            source.setCancelHandler { Darwin.close(descriptor) }
            readSource = source
            source.resume()
        }
    }

    func send(_ message: JSON) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        guard data.count <= Self.maximumFrame else { throw CXError(message: "Runtime frame exceeds the size limit.") }
        data.append(10)
        try synchronized {
            guard !closed else { throw CXError(message: "Runtime is disconnected.") }
            guard outputBytes + data.count <= Self.maximumBuffered else { finish(); throw CXError(message: "Runtime client cannot keep up with output.") }
            output.append(data); outputBytes += data.count
            write()
        }
    }

    func close() { synchronized { finish() } }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    private func read() {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<16 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { finish(); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { finish() }
                return
            }
            var searchOffset = input.count
            input.append(contentsOf: bytes.prefix(count))
            while let end = input[input.index(input.startIndex, offsetBy: searchOffset)...].firstIndex(of: 10) {
                let data = Data(input[..<end])
                input.removeSubrange(...end)
                searchOffset = 0
                guard !data.isEmpty, data.count <= Self.maximumFrame,
                      let value = try? JSONSerialization.jsonObject(with: data), let message = value as? JSON else { finish(); return }
                deliveryBytes += data.count; deliveryMessages += 1
                guard deliveryBytes <= Self.maximumBuffered, deliveryMessages <= 256 else { finish(); return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onMessage(message)
                    self.queue.async { [weak self] in
                        guard let self, !self.closed else { return }
                        self.deliveryBytes -= data.count; self.deliveryMessages -= 1
                        if self.readPaused, self.deliveryBytes < Self.maximumBuffered / 2 {
                            self.readPaused = false; self.readSource?.resume()
                        }
                    }
                }
            }
            guard input.count <= Self.maximumFrame else { finish(); return }
            if deliveryBytes >= Self.maximumBuffered / 2 {
                readPaused = true; readSource?.suspend(); return
            }
        }
    }

    private func write() {
        guard !closed else { return }
        while outputIndex < output.count {
            let first = output[outputIndex]
            let count = first.withUnsafeBytes { bytes in Darwin.write(fd, bytes.baseAddress!.advanced(by: outputOffset), first.count - outputOffset) }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if writeSource == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                        source.setEventHandler { [weak self] in self?.write() }
                        writeSource = source; source.resume()
                    }
                } else { finish() }
                return
            }
            guard count > 0 else { finish(); return }
            outputOffset += count; outputBytes -= count
            if outputOffset == first.count {
                output[outputIndex] = Data()
                outputIndex += 1; outputOffset = 0
                if outputIndex >= 64, outputIndex * 2 >= output.count { output.removeFirst(outputIndex); outputIndex = 0 }
            }
        }
        output.removeAll(keepingCapacity: true); outputIndex = 0
        writeSource?.cancel(); writeSource = nil
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        if readPaused { readPaused = false; readSource?.resume() }
        writeSource?.cancel(); writeSource = nil
        if let source = readSource { source.cancel(); readSource = nil }
        else { Darwin.close(fd) }
        input.removeAll(); output.removeAll(); outputBytes = 0
        DispatchQueue.main.async { [weak self] in self?.onClose() }
    }

    deinit {
        if readPaused { readSource?.resume() }
        writeSource?.cancel()
        if let source = readSource { source.cancel() }
        else if !closed { Darwin.close(fd) }
    }
}

final class RuntimeListener: @unchecked Sendable {
    private let path: String
    private let onAccept: (RuntimeChannel) -> Void
    private let queue = DispatchQueue(label: "vcx.runtime.listener")
    private var source: DispatchSourceRead?
    private var lock: Int32 = -1
    private var ownsEndpoint = false

    init(path: String, onAccept: @escaping (RuntimeChannel) -> Void) { self.path = path; self.onAccept = onAccept }

    func start() throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: parent) { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var info = stat()
        guard lstat(parent, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else { throw CXError(message: "Runtime directory must be private and owned by this user.") }
        var address = try runtimeAddress(path)
        let descriptor = Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CXError(message: "Cannot open runtime ownership lock.") }
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw CXError(message: "Runtime endpoint is already owned or has unsafe permissions.") }
        lock = descriptor
        do {
            if lstat(path, &info) == 0 {
                guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw CXError(message: "Refusing to replace an unrelated runtime endpoint.") }
                guard unlink(path) == 0 else { throw CXError(message: "Cannot remove stale runtime socket.") }
            } else if errno != ENOENT { throw CXError(message: "Cannot inspect runtime socket.") }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw CXError(message: "Cannot create runtime listener.") }
            do {
                try runtimeDescriptor(fd)
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard result == 0 else { throw CXError(message: "Cannot bind runtime listener.") }
                ownsEndpoint = true
                guard chmod(path, 0o600) == 0, listen(fd, 64) == 0 else { throw CXError(message: "Cannot secure runtime listener.") }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.accept(fd) }
                source.setCancelHandler { Darwin.close(fd) }
                self.source = source; source.resume()
            } catch { Darwin.close(fd); throw error }
        } catch { close(); throw error }
    }

    private func accept(_ fd: Int32) {
        for _ in 0..<64 {
            let accepted = Darwin.accept(fd, nil, nil)
            if accepted < 0 { if errno == EINTR { continue }; return }
            guard runtimePeer(accepted) else { Darwin.close(accepted); continue }
            do {
                try runtimeDescriptor(accepted)
                let channel = RuntimeChannel(fd: accepted)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { channel.close(); return }
                    self.onAccept(channel)
                }
            } catch { Darwin.close(accepted) }
        }
    }

    func close() {
        source?.cancel(); source = nil
        if ownsEndpoint { unlink(path); ownsEndpoint = false }
        if lock >= 0 { flock(lock, LOCK_UN); Darwin.close(lock); lock = -1 }
    }
    deinit { close() }
}

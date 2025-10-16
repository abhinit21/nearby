import Foundation
import Darwin

/// The documented ADB SYNC v1 SEND/DATA/DONE stream. It connects only to the
/// app-owned numeric loopback server and selects the already-authorized serial.
/// Progress counts actual source bytes written, and completion requires adbd's OKAY.
final class ADBSyncUpload: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false
    private let port: Int
    private let serial: String
    private let source: FileTransferSource
    private let remotePath: String
    private let pacing: UploadPacing
    private let progress: @Sendable (Int64) -> Void

    init(port: Int, serial: String, source: FileTransferSource, remotePath: String,
         pacing: UploadPacing = UploadPacing(),
         progress: @escaping @Sendable (Int64) -> Void) {
        self.port = port; self.serial = serial; self.source = source
        self.remotePath = remotePath; self.pacing = pacing; self.progress = progress
    }

    func cancel() {
        lock.lock(); cancelled = true; let fd = descriptor
        // shutdown wakes a blocked read/write without allowing a recycled fd to
        // be closed from the cancellation thread. The worker owns the close.
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do { try perform(); continuation.resume() }
                catch { continuation.resume(throwing: isCancelled ? CancellationError() : error) }
            }
        }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func checkCancellation() throws { if isCancelled { throw CancellationError() } }

    private func perform() throws {
        try checkCancellation()
        guard (1...65535).contains(port), port != 5037, !serial.isEmpty, serial.utf8.count < 1024,
              remotePath.utf8.count < 1000 else { throw FileTransferError.unavailable }
        let file = Darwin.open(source.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw errno == ELOOP ? FileTransferError.regularFilesOnly : FileTransferError.unreadable }
        defer { Darwin.close(file) }
        var initial = stat()
        guard fstat(file, &initial) == 0, (initial.st_mode & S_IFMT) == S_IFREG else { throw FileTransferError.regularFilesOnly }
        guard initial.st_size == source.byteCount else { throw FileTransferError.changedSource }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FileTransferError.interrupted }
        lock.lock(); descriptor = fd; let alreadyCancelled = cancelled; lock.unlock()
        defer {
            lock.lock(); descriptor = -1
            Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd); lock.unlock()
        }
        if alreadyCancelled { throw CancellationError() }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw FileTransferError.interrupted }
        try service("host:transport:" + serial, fd: fd)
        try service("sync:", fd: fd)
        let remote = Data((remotePath + ",33152").utf8) // regular file, 0600; no symlink mode
        try send(packet("SEND", UInt32(remote.count)) + remote, fd: fd)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var total: Int64 = 0
        var lastReport = ProcessInfo.processInfo.systemUptime
        progress(0)
        while true {
            try checkCancellation()
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw FileTransferError.unreadable }
            if count == 0 { break }
            total += Int64(count)
            guard total <= source.byteCount else { throw FileTransferError.changedSource }
            try waitForUploadBudget(count, fd: fd)
            try send(packet("DATA", UInt32(count)) + Data(buffer.prefix(count)), fd: fd, monitorSyncFailure: true)
            let now = ProcessInfo.processInfo.systemUptime
            if total == Int64(count) || now - lastReport >= 0.1 || total == source.byteCount { progress(total); lastReport = now }
        }
        var final = stat()
        guard fstat(file, &final) == 0, total == source.byteCount,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else { throw FileTransferError.changedSource }
        let modified = UInt32(clamping: initial.st_mtimespec.tv_sec)
        try send(packet("DONE", modified), fd: fd, monitorSyncFailure: true)
        try syncReply(fd: fd, allowSuccess: true)
        progress(total)
    }

    private func waitForUploadBudget(_ byteCount: Int, fd: Int32) throws {
        while true {
            try checkCancellation()
            try pendingSyncFailure(fd: fd)
            let delay = pacing.consume(byteCount)
            guard delay > 0 else { return }
            // Waiting for bandwidth is deliberate, so it happens outside send's
            // ten-second I/O-stall timer. POLLIN still wakes immediately for a
            // remote FAIL; shutdown wakes cancellation. Short slices also pick
            // up rate changes without requiring a second wake-up descriptor.
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, min(100, ceil(delay * 1_000))))
            let ready = Darwin.poll(&event, 1, milliseconds)
            try checkCancellation()
            if ready < 0, errno != EINTR { throw FileTransferError.interrupted }
            if ready > 0 { try pendingSyncFailure(fd: fd) }
        }
    }

    private func syncReply(fd: Int32, allowSuccess: Bool) throws {
        let reply = try readExactly(8, fd: fd)
        let id = String(decoding: reply.prefix(4), as: UTF8.self)
        let length = reply.dropFirst(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        if id == "FAIL" {
            guard length <= 16_384 else { throw FileTransferError.protocolFailure }
            throw FileTransferError.fromRemote(String(decoding: try readExactly(Int(length), fd: fd), as: UTF8.self))
        }
        guard allowSuccess, id == "OKAY", length == 0 else { throw FileTransferError.protocolFailure }
    }

    private func service(_ name: String, fd: Int32) throws {
        let bytes = Data(name.utf8)
        guard bytes.count < 65_536 else { throw FileTransferError.protocolFailure }
        try send(Data(String(format: "%04x", bytes.count).utf8) + bytes, fd: fd)
        let reply = String(decoding: try readExactly(4, fd: fd), as: UTF8.self)
        if reply == "FAIL" {
            let text = String(decoding: try readExactly(4, fd: fd), as: UTF8.self)
            guard let count = Int(text, radix: 16), count <= 16_384 else { throw FileTransferError.protocolFailure }
            let error = String(decoding: try readExactly(count, fd: fd), as: UTF8.self)
            throw FileTransferError.fromRemote(error)
        }
        guard reply == "OKAY" else { throw FileTransferError.protocolFailure }
    }

    private func send(_ bytes: Data, fd: Int32, monitorSyncFailure: Bool = false) throws {
        var offset = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime
        while offset < bytes.count {
            try checkCancellation()
            if monitorSyncFailure { try pendingSyncFailure(fd: fd) }
            // An early device FAIL can arrive while the outgoing stream is
            // backpressured. Never block in send and hide that useful failure.
            let count = bytes.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                let events = Int16(POLLOUT | (monitorSyncFailure ? POLLIN : 0))
                var event = pollfd(fd: fd, events: events, revents: 0)
                let ready = Darwin.poll(&event, 1, 100)
                if ready < 0, errno != EINTR { throw FileTransferError.interrupted }
                if monitorSyncFailure { try pendingSyncFailure(fd: fd) }
                guard ProcessInfo.processInfo.systemUptime - lastProgress < 10 else { throw FileTransferError.interrupted }
                continue
            }
            if count <= 0, monitorSyncFailure { try pendingSyncFailure(fd: fd) }
            guard count > 0 else { throw FileTransferError.interrupted }
            offset += count; lastProgress = ProcessInfo.processInfo.systemUptime
        }
    }

    private func pendingSyncFailure(fd: Int32) throws {
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&event, 1, 0)
        if ready < 0, errno != EINTR { throw FileTransferError.interrupted }
        if ready > 0 {
            if event.revents & Int16(POLLIN) != 0 { try syncReply(fd: fd, allowSuccess: false) }
            if event.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw FileTransferError.interrupted }
        }
    }

    private func readExactly(_ count: Int, fd: Int32) throws -> Data {
        var result = Data(count: count), offset = 0
        while offset < count {
            try checkCancellation()
            let received = result.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else { throw FileTransferError.interrupted }
            offset += received
        }
        return result
    }

    private func packet(_ id: String, _ value: UInt32) -> Data {
        var result = Data(id.utf8), little = value.littleEndian
        withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        return result
    }
}

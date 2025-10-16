import Foundation
import Darwin

/// Cancels a queued clipboard write before it starts. A partially written wire
/// message must finish to keep the shared control channel correctly framed.
final class ScrcpyWriteTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !started else { return false }
        started = true
        return true
    }
}

final class ScrcpySocket: @unchecked Sendable {
    enum IOOperation: Equatable, Sendable { case readExactly, readAvailable, writeExactly }
    typealias DescriptorLeaseObserver = @Sendable (IOOperation, Int32, Int32) -> Void

    private let lock = NSLock()
    private var descriptor: Int32
    private var finishing = false
    private let writes = DispatchQueue(label: "Nearby.scrcpy.control-writes")
    private let descriptorLeaseObserver: DescriptorLeaseObserver?

    init(port: UInt16, descriptorLeaseObserver: DescriptorLeaseObserver? = nil) throws {
        self.descriptorLeaseObserver = descriptorLeaseObserver
        descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.error("create stream socket") }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { let error = Self.error("connect stream socket"); Darwin.close(descriptor); descriptor = -1; throw error }
    }

    deinit { close() }
    func close() {
        lock.lock(); let fd = descriptor; descriptor = -1; lock.unlock()
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
    }
    func readTimeout(_ seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        lock.lock(); defer { lock.unlock() }
        if descriptor >= 0 { setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) }
    }
    /// A duplicated descriptor pins the same endpoint for the entire operation.
    /// Closing the owner may recycle its integer immediately, but shutdown still
    /// interrupts every lease and an old operation can never use a new endpoint.
    private func leaseDescriptor(for operation: IOOperation) throws -> Int32 {
        lock.lock()
        guard descriptor >= 0 else { lock.unlock(); throw CancellationError() }
        let original = descriptor
        let leased = fcntl(original, F_DUPFD_CLOEXEC, 0)
        let failure = leased < 0 ? Self.error("lease phone stream") : nil
        lock.unlock()
        if let failure { throw failure }
        // An optional internal ordering hook lets tests stop exactly before the
        // first syscall. Production never installs this observer.
        descriptorLeaseObserver?(operation, original, leased)
        return leased
    }

    func readExactly(_ count: Int) throws -> Data {
        guard count >= 0 else { throw ScrcpyProtocolError.malformed("Invalid phone stream read length.") }
        guard count > 0 else { return Data() }
        let descriptor = try leaseDescriptor(for: .readExactly)
        defer { Darwin.close(descriptor) }
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            let received = result.withUnsafeMutableBytes { raw in
                Darwin.recv(descriptor, raw.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received == 0 { throw ScrcpyProtocolError.malformed("The phone closed the mirroring connection.") }
            if received < 0 {
                if errno == EINTR { continue }
                throw Self.error("read phone stream")
            }
            offset += received
        }
        return result
    }

    func readAvailable() throws -> Data {
        let descriptor = try leaseDescriptor(for: .readAvailable)
        defer { Darwin.close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ScrcpyProtocolError.malformed("The phone control connection ended.") }
            return Data(bytes.prefix(count))
        }
    }

    func send(_ bytes: Data, ticket: ScrcpyWriteTicket? = nil, onFailure: @escaping @Sendable (String) -> Void) {
        writes.async { [self] in
            lock.lock(); let shouldSend = !finishing; lock.unlock()
            guard shouldSend, ticket?.begin() ?? true else { return }
            do { try writeExactly(bytes) } catch { onFailure(error.localizedDescription) }
        }
    }

    /// Drop queued input, finish one bounded final write, then release the stream.
    /// The caller is never blocked by network I/O on the main actor.
    func finishSending(_ bytes: Data, completion: @escaping @Sendable () -> Void) {
        lock.lock(); finishing = true; lock.unlock()
        // Bound an already-running write too, even if a peer reads very slowly.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in close() }
        writes.async { [self] in
            try? writeExactly(bytes)
            completion()
        }
    }

    private func writeExactly(_ bytes: Data) throws {
        guard !bytes.isEmpty else { return }
        let descriptor = try leaseDescriptor(for: .writeExactly)
        defer { Darwin.close(descriptor) }
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw in
                Darwin.send(descriptor, raw.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { throw Self.error("send phone input") }
            offset += sent
        }
    }

    private static func error(_ operation: String) -> Error {
        ScrcpyProtocolError.malformed("Could not \(operation): \(String(cString: strerror(errno))).")
    }
}

/// Keeps only resources belonging to this session; never kills the shared ADB server.
final class ScrcpyResources: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var sockets: [ScrcpySocket] = []
    private var process: Process?
    private var log = ""
    let serial: String
    let remotePath: String
    private var forwardAllocation: Task<String, Error>?
    private var forwardConsumed = false
    func setForwardAllocation(_ task: Task<String, Error>) {
        lock.lock(); forwardAllocation = task; lock.unlock()
    }
    private func allocationTask() -> Task<String, Error>? {
        lock.lock(); defer { lock.unlock() }; return forwardAllocation
    }
    func takeForwardPort() async -> String? {
        let value: String?
        if let task = allocationTask() { value = try? await task.value }
        else { value = nil }
        return consumeForward(value)
    }
    private func consumeForward(_ value: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !forwardConsumed, let port = value?.trimmingCharacters(in: .whitespacesAndNewlines), UInt16(port) != nil else { return nil }
        forwardConsumed = true
        return port
    }
    init(serial: String, remotePath: String) { self.serial = serial; self.remotePath = remotePath }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    var logs: String { lock.lock(); defer { lock.unlock() }; return log }
    func appendLog(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock(); log = String((log + text).suffix(8192)); lock.unlock()
    }
    func add(_ socket: ScrcpySocket) throws {
        lock.lock()
        if closed { lock.unlock(); socket.close(); throw CancellationError() }
        sockets.append(socket); lock.unlock()
    }
    func setProcess(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func close() {
        lock.lock(); closed = true; let sockets = sockets; self.sockets = []
        let process = process; self.process = nil; lock.unlock()
        for socket in sockets { socket.close() }
        if let process, process.isRunning { process.terminate() }
    }
}

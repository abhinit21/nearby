import Foundation
import Darwin

/// A non-daemonized ADB child, owned by this app rather than the user's shared :5037
/// daemon. It inherits the same user key directory and the app's execution context.
@MainActor
public final class OwnedADBServer {
    public private(set) var serverPort: Int?
    public private(set) var lastExitDiagnostic: String?
    public var onUnexpectedExit: ((String) -> Void)?
    public var isRunning: Bool { child?.isRunning == true && client != nil }
    private let adbURL: URL
    private let startupTimeout: TimeInterval
    private var child: OwnedADBProcess?
    private var client: ADBClient?
    private var startupTask: Task<ADBClient, Error>?
    private var generation = UUID()

    public init(adbURL: URL, startupTimeout: TimeInterval = 8) {
        self.adbURL = adbURL; self.startupTimeout = max(0.2, startupTimeout)
    }

    public func start() async throws -> ADBClient {
        if let child, child.isRunning, let client { return client }
        if let startupTask { return try await startupTask.value }
        let token = UUID(); generation = token
        let task = Task { try await launch(generation: token) }
        startupTask = task
        defer { if generation == token { startupTask = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Signals only the Process this instance launched. Never sends `kill-server`.
    /// Call after ScrcpySession.stopAndWait() so its cleanup can still use ADB.
    public func stopOwnServer() async {
        generation = UUID()
        let startup = startupTask; startupTask = nil; startup?.cancel()
        let owned = child; child = nil; client = nil; serverPort = nil
        await owned?.stop()
        _ = try? await startup?.value
    }

    private func launch(generation token: UUID) async throws -> ADBClient {
        if let previous = child { child = nil; await previous.stop() }
        client = nil; serverPort = nil
        let deadline = ProcessInfo.processInfo.systemUptime + startupTimeout
        var lastError = "Nearby's Android service did not become ready."
        for attempt in 0..<3 {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            let port = try ADBLoopback.availablePort()
            let owned = try OwnedADBProcess(adbURL: adbURL, port: port) { [weak self] process, report in
                Task { @MainActor [weak self] in self?.didExit(process, report: report, generation: token) }
            }
            child = owned
            do {
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    guard owned.isRunning else {
                        let detail = Self.redactedDiagnostic(owned.diagnostic)
                        throw ADBError.command(detail.isEmpty ? "Nearby's Android service exited during startup." : detail)
                    }
                    let ready = await Task.detached(priority: .userInitiated) {
                        ADBLoopback.isADBReady(port: port)
                    }.value
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    if ready, owned.isRunning {
                        let result = ADBClient(executableURL: adbURL, serverPort: port)
                        client = result; serverPort = port
                        return result
                    }
                    try await Task.sleep(for: .milliseconds(60))
                }
                throw ADBError.command("Nearby's Android service did not become ready. Try opening Nearby again.")
            } catch {
                await owned.stop()
                if child === owned { child = nil }
                if error is CancellationError || Task.isCancelled || generation != token { throw CancellationError() }
                lastError = error.localizedDescription
                // Binding port zero then closing has a small allocation race. Retry
                // only a bind collision, with a new port and a newly tracked child.
                let collision = lastError.localizedCaseInsensitiveContains("address already in use") ||
                    lastError.localizedCaseInsensitiveContains("cannot bind")
                guard collision, attempt < 2, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw ADBError.command(lastError)
                }
            }
        }
        throw ADBError.command(lastError)
    }

    private func didExit(_ exited: OwnedADBProcess, report: OwnedADBExit, generation token: UUID) {
        guard generation == token, child === exited, !exited.stopRequested else { return }
        let detail = Self.redactedDiagnostic(report.diagnostic)
        let reason = report.wasSignal ? "signal" : "status"
        let message = "Android connection service exited unexpectedly (\(reason) \(report.status))." +
            (detail.isEmpty ? "" : "\n" + detail)
        lastExitDiagnostic = message
        // Startup errors are returned by start(); only a previously ready server
        // needs a separate health event. Invalidate it before calling app code.
        guard client != nil else { return }
        child = nil; client = nil; serverPort = nil
        onUnexpectedExit?(message)
    }

    static func redactedDiagnostic(_ original: String) -> String {
        var text = original.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let rules: [(String, String)] = [
            (#"\x1B\[[0-9;]*[A-Za-z]"#, ""),
            (#"(?i)host:pair:[^:\s]+"#, "host:pair:[redacted]"),
            (#"(?i)\b(password|passphrase|secret|pairing[_ -]?code)\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s;,]+)"#, "$1=[redacted]"),
            (#"(?i)\b[0-9a-f]{32}(?:[0-9a-f]{32})?\b"#, "[redacted]"),
            (#"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]{1,5})?\b"#, "[address]"),
            (#"(?i)\b(?:studio|adb)-[A-Za-z0-9._-]+"#, "[device]")
        ]
        for (pattern, replacement) in rules {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
            }
        }
        return String(text.suffix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct OwnedADBExit: Sendable {
    let status: Int32
    let wasSignal: Bool
    let diagnostic: String
}

private final class OwnedADBProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var log = Data()
    private var stopTask: Task<Void, Never>?
    private var intentionalStop = false
    private let readers = DispatchGroup()

    var isRunning: Bool { process.isRunning }
    var stopRequested: Bool { lock.lock(); defer { lock.unlock() }; return intentionalStop }
    var diagnostic: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: log, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(adbURL: URL, port: Int, onExit: @escaping @Sendable (OwnedADBProcess, OwnedADBExit) -> Void) throws {
        let process = Process(); self.process = process
        process.executableURL = adbURL
        // --one-device applies to USB discovery only. An unmatchable serial keeps
        // this wireless utility from competing with the user's USB ADB daemon.
        process.arguments = ["-L", "tcp:\(port)", "--one-device", "nearby-wireless-only", "server", "nodaemon"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ADB_TRACE")
        environment.removeValue(forKey: "ADB_SERVER_SOCKET")
        environment["ADB_REJECT_KILL_SERVER"] = "1"
        // Native Bonjour plus explicit authorized connection attempts are owned by
        // AppModel. Avoid racing those with ADB's independent auto-connect loop.
        environment["ADB_MDNS_AUTO_CONNECT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        readers.enter(); readers.enter()
        process.terminationHandler = { [weak self] exited in
            guard let self else { return }
            let status = exited.terminationStatus, wasSignal = exited.terminationReason == .uncaughtSignal
            DispatchQueue.global(qos: .utility).async { [self] in
                readers.wait()
                onExit(self, OwnedADBExit(status: status, wasSignal: wasSignal, diagnostic: diagnostic))
            }
        }
        do { try process.run() }
        catch { readers.leave(); readers.leave(); throw error }
        Task.detached(priority: .utility) { [self] in read(stdout.fileHandleForReading) }
        Task.detached(priority: .utility) { [self] in read(stderr.fileHandleForReading) }
    }

    func stop() async { await stoppingTask().value }

    private func stoppingTask() -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        if let stopTask { return stopTask }
        intentionalStop = true
        let task = Task.detached(priority: .userInitiated) { [self] in
            if process.isRunning { process.interrupt() }
            let force = DispatchWorkItem { [self] in
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6, execute: force)
            process.waitUntilExit()
            force.cancel()
        }
        stopTask = task
        return task
    }

    private func read(_ handle: FileHandle) {
        defer { try? handle.close(); readers.leave() }
        while true {
            let data = handle.availableData
            if data.isEmpty { return }
            lock.lock()
            log.append(data.suffix(16_384))
            if log.count > 16_384 { log.removeFirst(log.count - 16_384) }
            lock.unlock()
        }
    }
}

private enum ADBLoopback {
    static func availablePort() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ADBError.command("Couldn't create Nearby's local Android service socket.") }
        defer { Darwin.close(fd) }
        var address = loopback(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0 else { throw ADBError.command("Couldn't allocate Nearby's local Android service port.") }
        let port = Int(UInt16(bigEndian: address.sin_port))
        guard port > 0, port != 5037 else { throw ADBError.command("Couldn't allocate a private Android service port.") }
        return port
    }

    /// No `adb` subprocess here: a readiness check must never auto-launch a daemon.
    static func isADBReady(port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        var address = loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { return false }
            var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&event, 1, 200) > 0 else { return false }
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return false }
        }
        guard fcntl(fd, F_SETFL, flags) == 0 else { return false }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        let request = Array("000chost:version".utf8)
        let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { return false }
        var response = [UInt8](repeating: 0, count: 12), offset = 0
        while offset < response.count {
            let count = response.withUnsafeMutableBytes {
                Darwin.recv(fd, $0.baseAddress?.advanced(by: offset), $0.count - offset, 0)
            }
            guard count > 0 else { return false }
            offset += count
        }
        // The packaged 37.0.1 client speaks server protocol 41 (hex 0029).
        return String(decoding: response, as: UTF8.self) == "OKAY00040029"
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }
}

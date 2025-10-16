import Foundation
import Darwin

public struct CommandOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32
    public init(stdout: String, stderr: String, status: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.status = status
    }
}

public enum ADBError: LocalizedError, Sendable {
    case missingRuntime(String), command(String), timedOut, cancelled
    public var errorDescription: String? {
        switch self {
        case .missingRuntime(let s), .command(let s): s
        case .timedOut: "The device did not respond in time. Check Wi-Fi and Wireless debugging, then try again."
        case .cancelled: "Cancelled."
        }
    }
}

/// Commands are passed as an argument array, never interpolated into a local shell.
public final class ADBClient: @unchecked Sendable {
    public let executableURL: URL
    public let serverPort: Int?
    /// Explicit numeric loopback keeps commands on Nearby's private server. The
    /// supported ADB client fails rather than auto-launching a missing numeric-host server.
    public var baseArguments: [String] {
        serverPort.map { ["-H", "127.0.0.1", "-P", String($0)] } ?? []
    }
    public init(executableURL: URL, serverPort: Int? = nil) {
        self.executableURL = executableURL; self.serverPort = serverPort
    }
    public func run(_ arguments: [String], timeout: TimeInterval = 15) async throws -> CommandOutput {
        let command = CommandExecution(executableURL: executableURL, arguments: baseArguments + arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await command.execute()
        } onCancel: { command.cancel() }
    }
    public func checked(_ arguments: [String], timeout: TimeInterval = 15) async throws -> String {
        let result = try await run(arguments, timeout: timeout)
        guard result.status == 0 else {
            let detail = [result.stderr, result.stdout].filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            throw ADBError.command(detail.isEmpty ? "Android Debug Bridge could not complete the request." : String(detail.prefix(1200)))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class CommandExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    init(executableURL: URL, arguments: [String], timeout: TimeInterval) {
        self.executableURL = executableURL; self.arguments = arguments; self.timeout = timeout
    }
    func cancel() { terminate(timedOut: false) }
    private func terminate(timedOut: Bool) {
        lock.lock()
        if timedOut { self.timedOut = true } else { cancelled = true }
        let p = process
        lock.unlock()
        if let p, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
                if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
            }
        }
    }
    func execute() async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                let p = Process(); process = p
                p.executableURL = executableURL; p.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                p.environment = environment
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { lock.unlock(); continuation.resume(throwing: error); return }
                lock.unlock()
                let deadline = DispatchWorkItem { [weak self] in self?.terminate(timedOut: true) }
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0.05, timeout), execute: deadline)
                let stdout = DataCollector(), stderr = DataCollector(), group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { stdout.read(out.fileHandleForReading); group.leave() }
                group.enter()
                DispatchQueue.global().async { stderr.read(err.fileHandleForReading); group.leave() }
                p.waitUntilExit(); deadline.cancel(); group.wait()
                lock.lock(); let wasCancelled = cancelled, wasTimedOut = timedOut; process = nil; lock.unlock()
                if wasCancelled { continuation.resume(throwing: CancellationError()) }
                else if wasTimedOut { continuation.resume(throwing: ADBError.timedOut) }
                else { continuation.resume(returning: CommandOutput(stdout: stdout.string, stderr: stderr.string, status: p.terminationStatus)) }
            }
        }
    }
}

private final class DataCollector: @unchecked Sendable {
    private var data = Data()
    var string: String { String(decoding: data, as: UTF8.self) }
    func read(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count < 1_048_576 { data.append(chunk.prefix(1_048_576 - data.count)) }
        }
    }
}

public struct RuntimeTools: Sendable {
    public let adbURL: URL
    public let serverURL: URL
    public let serverVersion: String
    public static func locate() throws -> RuntimeTools {
        let fm = FileManager.default
        var roots = [URL]()
        if let resources = Bundle.main.resourceURL { roots.append(resources.appendingPathComponent("Runtime")) }
        // Resource accessor bundle for command-line SwiftPM builds and packaged apps.
        for folder in [Bundle.main.bundleURL, Bundle.main.bundleURL.deletingLastPathComponent(), Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"), URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()] {
            roots.append(folder.appendingPathComponent("Nearby_Nearby.bundle/Runtime"))
            roots.append(folder.appendingPathComponent("Nearby_Nearby.bundle/Contents/Resources/Runtime"))
        }
        if let override = ProcessInfo.processInfo.environment["NEARBY_RUNTIME_DIR"] { roots.insert(URL(fileURLWithPath: override), at: 0) }
        for root in roots {
            let adb = root.appendingPathComponent("adb"), server = root.appendingPathComponent("scrcpy-server-v3.3.4")
            if fm.isExecutableFile(atPath: adb.path), fm.fileExists(atPath: server.path) {
                return RuntimeTools(adbURL: adb, serverURL: server, serverVersion: "3.3.4")
            }
        }
        // Development fallback only. Packaged application includes both tools.
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let adb = URL(fileURLWithPath: prefix + "/bin/adb"), server = URL(fileURLWithPath: prefix + "/share/scrcpy/scrcpy-server")
            if fm.isExecutableFile(atPath: adb.path), fm.fileExists(atPath: server.path) {
                return RuntimeTools(adbURL: adb, serverURL: server, serverVersion: "3.3.4")
            }
        }
        throw ADBError.missingRuntime("Nearby's Android tools are missing. Rebuild the app with scripts/build-app.sh.")
    }
}

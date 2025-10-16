import Foundation
import Combine
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CoreImage

public struct StreamOptions: Sendable, Equatable {
    public var maxSize: Int
    public var bitRate: Int
    public var maxFPS: Int
    public var audio: Bool
    public init(maxSize: Int = 1920, bitRate: Int = 8_000_000, maxFPS: Int = 60, audio: Bool = false) {
        self.maxSize = maxSize; self.bitRate = bitRate; self.maxFPS = maxFPS; self.audio = audio
    }
}

@MainActor public final class ScrcpySession: ObservableObject {
    public static let protocolVersion = "3.3.4"
    public let displayLayer = AVSampleBufferDisplayLayer()
    @Published public private(set) var videoSize = CGSize(width: 300, height: 667)
    @Published public private(set) var isStreaming = false
    public private(set) var isTouchActive = false
    public private(set) var decodedFrameCount = 0
    public var onFirstFrame: (() -> Void)?
    public var onEnded: ((String?) -> Void)?
    public var onClipboard: ((String) -> Void)?
    public var onPerformanceSample: ((StreamPerformanceSample) -> Void)?

    private var adb: ADBClient
    private let serverURL: URL
    private let serverVersion: String
    private var resources: ScrcpyResources?
    private var videoWorker: ScrcpyVideoWorker?
    private var performanceTask: Task<Void, Never>?
    // Internal ordering hook verifies the production processing queue using the
    // local protocol peer; never installed by the application.
    var videoProcessingObserver: (@Sendable () -> Void)?
    private var control: ScrcpySocket?
    private var latestPixelBuffer: CVPixelBuffer?
    private var startupWaiter: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didOverrideDisplayPower = false
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    private struct PendingClipboard {
        let owned: ScrcpyResources
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
        let ticket: ScrcpyWriteTicket
    }
    private var clipboardSequence: UInt64 = 0
    private var pendingClipboard: [UInt64: PendingClipboard] = [:]
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    public init(adb: ADBClient, serverURL: URL, serverVersion: String) {
        self.adb = adb; self.serverURL = serverURL; self.serverVersion = serverVersion
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    public func start(serial: String, options: StreamOptions = StreamOptions(), using client: ADBClient? = nil,
                      startupTimeout: TimeInterval = 15) async throws {
        stop()
        if let client { adb = client }
        decodedFrameCount = 0
        guard serverVersion == Self.protocolVersion else {
            throw ScrcpyProtocolError.malformed("Nearby requires scrcpy server \(Self.protocolVersion); found \(serverVersion).")
        }
        guard !options.audio else {
            throw ScrcpyProtocolError.malformed("Phone audio playback is not implemented in this build. Start with audio off.")
        }
        guard FileManager.default.fileExists(atPath: serverURL.path) else {
            throw ScrcpyProtocolError.malformed("The bundled scrcpy server is missing.")
        }
        let id = String(format: "%08x", UInt32.random(in: 1...0x7fffffff))
        let owned = ScrcpyResources(serial: serial, remotePath: "/data/local/tmp/nearby-scrcpy-\(id).jar")
        resources = owned
        let startupSeconds = startupTimeout.isFinite ? min(15, max(0.1, startupTimeout)) : 15
        let deadline = Date().addingTimeInterval(startupSeconds)
        func remaining() throws -> TimeInterval {
            guard self.resources === owned, !Task.isCancelled else { throw CancellationError() }
            let value = deadline.timeIntervalSinceNow
            guard value > 0 else { throw ScrcpyProtocolError.malformed("Starting the phone stream timed out.") }
            return value
        }
        do {
            _ = try await adb.checked(["-s", serial, "push", serverURL.path, owned.remotePath], timeout: min(10, try remaining()))
            let adb = adb
            let allocationTimeout = min(3, try remaining())
            // Allocation is short and cancellation-shielded: discarding its stdout
            // after adb creates a port would make precise cleanup impossible.
            let allocation = Task.detached {
                try await adb.checked(["-s", serial, "forward", "tcp:0", "localabstract:scrcpy_\(id)"], timeout: allocationTimeout)
            }
            owned.setForwardAllocation(allocation)
            let port = try await allocation.value
            guard let number = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0 else {
                throw ScrcpyProtocolError.malformed("ADB did not allocate a local stream port.")
            }
            _ = try remaining()
            let process = Process()
            process.executableURL = adb.executableURL
            process.arguments = adb.baseArguments + ["-s", serial, "shell", "CLASSPATH=\(owned.remotePath)", "app_process", "/", "com.genymobile.scrcpy.Server", serverVersion,
                "scid=\(id)", "log_level=warn", "video=true", "audio=false", "control=true", "tunnel_forward=true",
                "video_codec=h264", "max_size=\(min(8192, max(256, options.maxSize)))", "video_bit_rate=\(max(100_000, options.bitRate))",
                "max_fps=\(min(120, max(1, options.maxFPS)))", "clipboard_autosync=true", "cleanup=true"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { owned.appendLog(data) }
            }
            try owned.setProcess(process)
            let worker = ScrcpyVideoWorker(owned: owned, onConnected: { [weak self] controls, size in
                DispatchQueue.main.async { self?.connected(controls, size: size, owned: owned) }
            }, onDeviceMessage: { [weak self] message in
                // The control reader runs on a background dispatch queue. Wait
                // for this ordered handoff before consuming another message so
                // clipboard updates/ACKs cannot build an unbounded UI queue.
                // stop never joins synchronously; stopAndWait suspends while its
                // detached cleanup waits, leaving the UI free to finish here.
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self?.deviceMessageReceived(message, owned: owned) }
                }
            }, onFrameAvailable: { [weak self] in
                DispatchQueue.main.async { self?.drainFrame(owned: owned) }
            }, onError: { [weak self] message in
                DispatchQueue.main.async { self?.fail(message, owned: owned) }
            }, processingObserver: videoProcessingObserver)
            videoWorker = worker
            let seconds = try remaining()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    startupWaiter = continuation
                    timeoutTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(seconds))
                        guard !Task.isCancelled else { return }
                        self?.fail("Starting the phone stream timed out. \(owned.logs)", owned: owned)
                    }
                    worker.start(port: number, deadline: deadline)
                }
            } onCancel: {
                owned.close()
                Task { @MainActor [weak self] in
                    if self?.resources === owned { self?.stop() }
                }
            }
        } catch {
            if resources === owned { stop() } else { cleanup(owned) }
            throw error
        }
    }

    private func connected(_ socket: ScrcpySocket, size: CGSize, owned: ScrcpyResources) {
        guard resources === owned else { socket.close(); return }
        control = socket; videoSize = size
    }
    private func drainFrame(owned: ScrcpyResources) {
        guard resources === owned, !owned.isClosed, let worker = videoWorker else { return }
        if let frame = worker.frames.takeForDrain() { receive(frame, owned: owned, worker: worker) }
        if worker.frames.finishDrain() {
            DispatchQueue.main.async { [weak self] in self?.drainFrame(owned: owned) }
        }
    }
    private func deviceMessageReceived(_ message: ScrcpyDeviceMessage, owned: ScrcpyResources) {
        guard resources === owned, isStreaming else { return }
        switch message {
        case .clipboard(let text): onClipboard?(text)
        case .clipboardAcknowledgement(let sequence): completeClipboard(sequence, owned: owned, result: .success(()))
        }
    }
    private func receive(_ frame: PreparedVideoFrame, owned: ScrcpyResources, worker: ScrcpyVideoWorker) {
        guard resources === owned, !owned.isClosed else { return }
        latestPixelBuffer = frame.decoded.pixelBuffer
        if videoSize != frame.size { videoSize = frame.size }
        let renderer = displayLayer.sampleBufferRenderer
        let flushed = renderer.status == .failed || !renderer.isReadyForMoreMediaData
        if flushed { renderer.flush() }
        renderer.enqueue(frame.sample)
        worker.performance.presented(receivedAt: frame.decoded.receivedAt, at: scrcpyMonotonicTime(), flushed: flushed)
        decodedFrameCount += 1
        if !isStreaming {
            isStreaming = true; timeoutTask?.cancel(); timeoutTask = nil
            let waiter = startupWaiter; startupWaiter = nil; waiter?.resume()
            startPerformanceSamples(owned: owned, worker: worker)
            onFirstFrame?()
        }
    }

    private func startPerformanceSamples(owned: ScrcpyResources, worker: ScrcpyVideoWorker) {
        performanceTask?.cancel()
        performanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.resources === owned, !owned.isClosed, !Task.isCancelled else { return }
                self.onPerformanceSample?(worker.performance.takeSample())
            }
        }
    }

    public func stop() {
        let owned = resources; resources = nil
        cancelClipboardTransfers(reason: .connectionLost)
        let restoreControl = didOverrideDisplayPower ? control : nil
        didOverrideDisplayPower = false
        timeoutTask?.cancel(); timeoutTask = nil
        performanceTask?.cancel(); performanceTask = nil
        let waiter = startupWaiter; startupWaiter = nil; waiter?.resume(throwing: CancellationError())
        let worker = videoWorker; videoWorker = nil
        worker?.cancel(); control = nil
        latestPixelBuffer = nil; isStreaming = false; isTouchActive = false
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        if let owned { cleanup(owned, restoreControl: restoreControl, worker: worker) }
    }

    /// Quit paths await owned cleanup before allowing the process to exit. A
    /// stalled native decoder join is canceled at the 5.5-second quit deadline;
    /// its closed generation remains unable to deliver frames.
    /// Final control writes have a two-second deadline; both ADB cleanup commands
    /// run concurrently with two-second deadlines (plus process termination grace).
    public func stopAndWait() async {
        await stopAndWait(cleanupTimeout: .milliseconds(5_500))
    }

    // A short deadline lets the local peer tests exercise a stuck decoder
    // without imposing the real quit-path deadline on every test run.
    func stopAndWait(cleanupTimeout: Duration) async {
        stop()
        let pending = cleanupTasks
        let deadline = Task {
            try? await Task.sleep(for: cleanupTimeout)
            guard !Task.isCancelled else { return }
            for task in pending.values { task.cancel() }
        }
        await withTaskGroup(of: Void.self) { group in
            for task in pending.values { group.addTask { await task.value } }
            await group.waitForAll()
        }
        deadline.cancel()
        for id in pending.keys { cleanupTasks.removeValue(forKey: id) }
    }
    private func fail(_ message: String, owned: ScrcpyResources) {
        guard resources === owned else { return }
        let wasStreaming = isStreaming
        let waiter = startupWaiter; startupWaiter = nil
        waiter?.resume(throwing: ScrcpyProtocolError.malformed(message))
        stop()
        if wasStreaming { onEnded?(message) }
    }
    private func cleanup(_ owned: ScrcpyResources, restoreControl: ScrcpySocket? = nil, worker: ScrcpyVideoWorker? = nil) {
        let adb = adb
        let id = UUID()
        let task = Task.detached {
            if let restoreControl {
                await withCheckedContinuation { continuation in
                    restoreControl.finishSending(ControlProtocol.screenPower(true)) { continuation.resume() }
                }
            }
            owned.close()
            let port = await owned.takeForwardPort()
            await withTaskGroup(of: Void.self) { group in
                if let port, UInt16(port) != nil {
                    group.addTask {
                        _ = try? await adb.run(["-s", owned.serial, "forward", "--remove", "tcp:\(port)"], timeout: 2)
                    }
                }
                group.addTask {
                    _ = try? await adb.run(["-s", owned.serial, "shell", "rm", "-f", owned.remotePath], timeout: 2)
                }
                await group.waitForAll()
            }
            // Remove our ADB forward and remote file before waiting on native
            // decoder completion. Cancellation can end a stuck native join at
            // the quit deadline without skipping those owned cleanup commands.
            // The worker retains its own decoder until its queue can invalidate
            // it; canceled generations cannot deliver frames in the meantime.
            await worker?.waitUntilStopped()
        }
        // v3.3.4 cleanup=true also restores display power on the Android side.
        // Give an explicit local override its final on message before closing.
        cleanupTasks[id] = task
        Task { [weak self] in
            await task.value
            self?.cleanupTasks.removeValue(forKey: id)
        }
    }

    private func send(_ data: Data) {
        guard isStreaming, let owned = resources, let control else { return }
        control.send(data) { [weak self] message in
            Task { @MainActor [weak self] in self?.fail(message, owned: owned) }
        }
    }
    public func keycode(_ code: UInt32, metaState: UInt32 = 0) {
        send(ControlProtocol.keycode(code, down: true, metaState: metaState) + ControlProtocol.keycode(code, down: false, metaState: metaState))
    }
    public func text(_ text: String) { send(ControlProtocol.text(text)) }
    public func touch(x: Double, y: Double, phase: TouchPhase) {
        guard isStreaming else { return }
        switch phase {
        case .down, .move: isTouchActive = true
        case .up: isTouchActive = false
        }
        send(ControlProtocol.touch(x: x, y: y, width: Int(videoSize.width), height: Int(videoSize.height), phase: phase))
    }
    public func scroll(x: Double, y: Double, dx: Double, dy: Double) {
        send(ControlProtocol.scroll(x: x, y: y, width: Int(videoSize.width), height: Int(videoSize.height), dx: dx, dy: dy))
    }
    public func setScreenPower(_ on: Bool) {
        guard isStreaming else { return }
        if !on { didOverrideDisplayPower = true }
        send(ControlProtocol.screenPower(on))
    }
    /// UTF-8 clipboard transport avoids Android's key-character-map limits.
    /// Acknowledgement confirms the server processed the request; Android does
    /// not report whether the selected app accepted its asynchronous Paste key.
    public func sendClipboard(_ text: String, paste: Bool, timeout: TimeInterval = 3) async throws {
        guard isStreaming, let owned = resources, let control else { throw ClipboardFailure.unavailable }
        guard text.utf8.count <= ClipboardTransferLimits.maximumTextBytes else { throw ClipboardFailure.tooLarge }
        guard pendingClipboard.count < 8 else { throw ClipboardFailure.busy }
        try Task.checkCancellation()
        clipboardSequence = clipboardSequence == UInt64.max ? 1 : clipboardSequence + 1
        let sequence = clipboardSequence
        let packet = try ControlProtocol.clipboard(text, paste: paste, sequence: sequence)
        let seconds = timeout.isFinite ? min(10, max(0.05, timeout)) : 3
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ticket = ScrcpyWriteTicket()
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                    self?.completeClipboard(sequence, owned: owned, result: .failure(ClipboardFailure.timedOut))
                }
                pendingClipboard[sequence] = PendingClipboard(owned: owned, continuation: continuation, timeout: timeoutTask, ticket: ticket)
                control.send(packet, ticket: ticket) { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.completeClipboard(sequence, owned: owned, result: .failure(ClipboardFailure.connectionLost))
                        self?.fail(message, owned: owned)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.completeClipboard(sequence, owned: owned, result: .failure(CancellationError()))
            }
        }
    }

    /// Cancels pending acknowledgements and drops clipboard writes that have not
    /// started. Call when the mirror loses focus or clipboard sharing is paused.
    public func cancelClipboardTransfers() { cancelClipboardTransfers(reason: .cancelled) }

    private func cancelClipboardTransfers(reason: ClipboardFailure) {
        let pending = pendingClipboard
        pendingClipboard.removeAll()
        for operation in pending.values {
            operation.ticket.cancel()
            operation.timeout.cancel()
            operation.continuation.resume(throwing: reason)
        }
    }

    private func completeClipboard(_ sequence: UInt64, owned: ScrcpyResources, result: Result<Void, Error>) {
        guard let operation = pendingClipboard[sequence], operation.owned === owned else { return }
        pendingClipboard.removeValue(forKey: sequence)
        operation.ticket.cancel()
        operation.timeout.cancel()
        operation.continuation.resume(with: result)
    }

    /// Compatibility for callers that do not display an acknowledgement state.
    /// New app actions use sendClipboard and present its bounded failure result.
    public func setClipboard(_ text: String, paste: Bool) {
        Task { [weak self] in try? await self?.sendClipboard(text, paste: paste) }
    }
    public func screenshot() -> CGImage? {
        guard isStreaming, let latestPixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: latestPixelBuffer)
        return imageContext.createCGImage(image, from: image.extent)
    }
}

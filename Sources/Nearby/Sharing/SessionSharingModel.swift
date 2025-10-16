import AppKit
import Combine
import NearbyCore

@MainActor
protocol ClipboardSessionTransport: AnyObject {
    var isStreaming: Bool { get }
    var onClipboard: ((String) -> Void)? { get set }
    func sendClipboard(_ text: String, paste: Bool, timeout: TimeInterval) async throws
    func cancelClipboardTransfers()
}

extension ScrcpySession: ClipboardSessionTransport {}

@MainActor
protocol TextPasteboard: AnyObject {
    var changeCount: Int { get }
    func readText() -> String?
    func replaceText(_ text: String) -> Bool
}

extension NSPasteboard: TextPasteboard {
    func readText() -> String? { string(forType: .string) }
    func replaceText(_ text: String) -> Bool {
        clearContents()
        return setString(text, forType: .string)
    }
}

/// Owns text and file operations for exactly one foreground mirror session.
/// No clipboard contents are retained in UI state or diagnostic strings.
@MainActor
final class SessionSharingModel: ObservableObject {
    @Published private(set) var clipboardStatus: ClipboardSharingStatus = .unavailable
    @Published private(set) var pasteMessage: String?
    @Published private(set) var pasteFailed = false
    @Published private(set) var transfers: FileTransferCoordinator?
    @Published var dropTargeted = false
    @Published private(set) var dropMessage: String?
    weak var model: AppModel?
    private weak var engine: (any ClipboardSessionTransport)?
    private let pasteboard: any TextPasteboard
    private let foregroundPredicate: (() -> Bool)?
    private let sharingPredicate: (() -> Bool)?
    private let observesApplication: Bool
    private var generation: UUID?
    private var policy = ClipboardSyncPolicy()
    private var pollTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var transferSessionTask: Task<Void, Never>?
    private var transferBindingID = UUID()
    private var operationID = UUID()
    private var sendingAutomatically = false
    private var lastOperationWasPaste = false
    private var isReconfiguringVideo = false
    private var observers: [NSObjectProtocol] = []

    init(pasteboard: any TextPasteboard = NSPasteboard.general, foreground: (() -> Bool)? = nil,
         sharingEnabled: (() -> Bool)? = nil, observesApplication: Bool = true,
         transfers: FileTransferCoordinator? = nil) {
        self.pasteboard = pasteboard
        foregroundPredicate = foreground
        sharingPredicate = sharingEnabled
        self.observesApplication = observesApplication
        self.transfers = transfers
    }

    var canSend: Bool { !isReconfiguringVideo && engine?.isStreaming == true && generation != nil }
    var isSendingText: Bool { sendTask != nil }
    var isForeground: Bool { foregroundPredicate?() ?? (NSApp.isActive && model?.mirrorWindow?.isSessionForeground == true) }
    private var sharingEnabled: Bool { sharingPredicate?() ?? model?.shareClipboard ?? true }

    var clipboardDescription: String {
        switch clipboardStatus {
        case .disabled: "Off · automatic text sharing is disabled."
        case .unavailable: "Unavailable · reconnect to share text."
        case .paused: "Paused · activate the Pixel mirror to share text."
        case .ready: "Ready · shares text while this mirror is active."
        case .sending: "Sending text to Pixel…"
        case .failed(let failure): "Failed · " + failure.localizedDescription
        }
    }

    func configure(model: AppModel?, engine: any ClipboardSessionTransport, generation: UUID) {
        if self.engine !== engine || self.generation != generation {
            cancelTextOperation()
            pasteMessage = nil; pasteFailed = false; lastOperationWasPaste = false
        }
        self.model = model
        self.engine = engine
        self.generation = generation
        if observesApplication, observers.isEmpty {
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshContext() }
                })
            }
        }
        engine.onClipboard = { [weak self, weak engine] text in
            guard let self, self.generation == generation, self.engine === engine else { return }
            refreshContext()
            guard policy.shouldApplyRemoteText(text, sessionID: generation, currentLocalText: pasteboard.readText()) else { return }
            if pasteboard.replaceText(text) {
                policy.remoteWriteCompleted(changeCount: pasteboard.changeCount, sessionID: generation)
                if clipboardStatus == .failed(.localWriteFailed) { policy.clearFailure() }
            } else {
                policy.sendFailed(.localWriteFailed, sessionID: generation)
            }
            clipboardStatus = policy.status
        }
        refreshContext()
    }

    func becameActive() {
        isReconfiguringVideo = false
        pollTask?.cancel()
        refreshContext()
        transferBindingID = UUID(); configureTransfers()
        startClipboardPolling()
    }

    private func startClipboardPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, engine?.isStreaming == true else { return }
                pollClipboard()
            }
        }
    }

    /// Video restarts leave the independently owned file stream bound to the
    /// same verified phone. Clipboard baselines are reset across the pause.
    func pauseForVideoReconfiguration() {
        isReconfiguringVideo = true
        pollTask?.cancel(); pollTask = nil
        refreshContext()
    }

    func resumeAfterVideoReconfiguration() {
        isReconfiguringVideo = false
        refreshContext()
        startClipboardPolling()
    }

    /// Shared by the native polling loop and deterministic lifecycle tests.
    func pollClipboard() {
        refreshContext()
        guard let generation, canSend, sendTask == nil else { return }
        do {
            if let text = try policy.automaticText(pasteboard.readText(), changeCount: pasteboard.changeCount, sessionID: generation) {
                send(text, paste: false, generation: generation)
            }
        } catch {
            clipboardStatus = policy.status
        }
    }

    func becameInactive() {
        isReconfiguringVideo = false
        pollTask?.cancel(); pollTask = nil
        cancelTextOperation()
        pasteMessage = nil; pasteFailed = false; dropTargeted = false
        policy.configure(sessionID: generation, isStreaming: false, isForeground: false,
                         enabled: sharingEnabled, pasteboardChangeCount: pasteboard.changeCount)
        clipboardStatus = policy.status
        transferBindingID = UUID()
        let previous = transferSessionTask
        let coordinator = transfers
        transferSessionTask = Task {
            await previous?.value
            await coordinator?.setSession(nil, adb: nil)
        }
    }

    func stopAndWait() async {
        becameInactive()
        await transferSessionTask?.value
    }

    func refreshContext() {
        let foreground = isForeground
        if (!canSend || !foreground || (sendingAutomatically && !sharingEnabled)), sendTask != nil {
            cancelTextOperation()
        }
        policy.configure(sessionID: generation, isStreaming: canSend, isForeground: foreground,
                         enabled: sharingEnabled, pasteboardChangeCount: pasteboard.changeCount)
        clipboardStatus = policy.status
    }

    func pasteToPixel() {
        refreshContext()
        lastOperationWasPaste = true
        guard let generation else { pasteMessage = ClipboardFailure.unavailable.localizedDescription; return }
        do {
            let text = try policy.validatePaste(pasteboard.readText(), sessionID: generation)
            send(text, paste: true, generation: generation)
        } catch let failure as ClipboardFailure {
            pasteMessage = failure.localizedDescription
            pasteFailed = true
            policy.sendFailed(failure, sessionID: generation)
            clipboardStatus = policy.status
        } catch { pasteMessage = "Text could not be sent. Try again." }
    }

    func retryClipboard() {
        let localFailure = clipboardStatus == .failed(.localWriteFailed)
        if !localFailure, lastOperationWasPaste { pasteToPixel(); return }
        policy.clearFailure(); pasteMessage = nil; pasteFailed = false; refreshContext()
        if localFailure { pasteMessage = "Copy the text again on Pixel while this mirror is active."; return }
        guard let generation, canSend, isForeground, sharingEnabled else { return }
        do {
            let text = try policy.validatePaste(pasteboard.readText(), sessionID: generation)
            send(text, paste: false, generation: generation)
        } catch let failure as ClipboardFailure {
            policy.sendFailed(failure, sessionID: generation); clipboardStatus = policy.status
        } catch { }
    }

    private func cancelTextOperation() {
        engine?.cancelClipboardTransfers()
        sendTask?.cancel(); sendTask = nil; operationID = UUID(); sendingAutomatically = false
    }

    private func send(_ text: String, paste: Bool, generation: UUID) {
        guard let engine, self.generation == generation, sendTask == nil else { return }
        let operation = UUID(); operationID = operation
        lastOperationWasPaste = paste
        sendingAutomatically = !paste
        policy.sendStarted(text: text, sessionID: generation); clipboardStatus = policy.status
        pasteMessage = nil; pasteFailed = false
        sendTask = Task { [weak self, weak engine] in
            guard let self, let engine else { return }
            do {
                try await engine.sendClipboard(text, paste: paste, timeout: 3)
                guard !Task.isCancelled, operationID == operation, self.generation == generation, self.engine === engine else { return }
                policy.sendSucceeded(sessionID: generation)
                if paste { pasteMessage = "Sent to Pixel. Choose a text field on Pixel to paste into." }
            } catch {
                guard !Task.isCancelled, operationID == operation, self.generation == generation else { return }
                let failure = error as? ClipboardFailure ?? .connectionLost
                policy.sendFailed(failure, sessionID: generation)
                if paste { pasteMessage = failure.localizedDescription; pasteFailed = true }
            }
            guard operationID == operation else { return }
            sendTask = nil; sendingAutomatically = false; clipboardStatus = policy.status
        }
    }

    private func configureTransfers() {
        guard let model, let adb = model.adb, let generation, let device = model.activeDevice else { return }
        if transfers == nil {
            transfers = FileTransferCoordinator(helperURL: adb.executableURL.deletingLastPathComponent().appendingPathComponent("nearby-transfer-arm64-v8a"))
        }
        updateUploadPacing()
        let coordinator = transfers
        let binding = transferBindingID
        let transferSession = FileTransferSession(id: binding, deviceID: device.id, serial: device.serial)
        // The coordinator serializes teardown and cleanup before accepting work.
        let prior = transferSessionTask
        transferSessionTask = Task { [weak self] in
            await prior?.value
            guard let self, generation == self.generation, transferBindingID == binding,
                  canSend || isReconfiguringVideo else { return }
            await coordinator?.setSession(transferSession, adb: adb)
        }
    }

    func updateUploadPacing() {
        if let model { transfers?.setUploadRateLimit(bytesPerSecond: model.uploadRateLimit) }
    }

    func acceptFiles(_ urls: [URL]) {
        dropTargeted = false
        guard canSend, let transfers else {
            dropMessage = "Reconnect to your Pixel before sending files."
            model?.showSharing(); return
        }
        guard !urls.isEmpty else { dropMessage = "Drag regular files from Finder, or choose files."; return }
        dropMessage = nil
        let binding = transferBindingID, pending = transferSessionTask
        Task { [weak self] in
            await pending?.value
            // This request was accepted while streaming. A video-only quality
            // restart cannot revoke it; disconnect still changes the binding.
            guard let self, transferBindingID == binding else { return }
            transfers.enqueue(urls)
        }
        model?.showSharing()
    }

    func chooseFiles() {
        guard canSend else { dropMessage = "Reconnect to your Pixel before sending files."; return }
        let panel = NSOpenPanel()
        panel.message = "Send files to your Pixel’s Downloads folder. Existing files are kept."
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        acceptFiles(panel.urls)
    }
}

@MainActor
extension AppModel {
    func configureSessionClipboard(engine: ScrcpySession, generation: UUID) {
        sharing.configure(model: self, engine: engine, generation: generation)
    }
    func sessionBecameActive(engine: ScrcpySession, generation: UUID) {
        sharing.configure(model: self, engine: engine, generation: generation)
        sharing.becameActive()
    }
    func sessionBecameInactive() { pauseQualityForInterruption(); sharing.becameInactive() }
    func pasteToPixel() { showSharing(); sharing.pasteToPixel() }
    func showSharing() { mirrorWindow?.showSharing() }
}

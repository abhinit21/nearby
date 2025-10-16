import Foundation
import Combine
import Darwin

public struct FileTransferSession: Equatable, Sendable {
    public let id: UUID
    public let deviceID: String
    public let serial: String
    public init(id: UUID, deviceID: String, serial: String) {
        self.id = id; self.deviceID = deviceID; self.serial = serial
    }
}

public enum FileTransferState: String, Sendable, Hashable {
    case queued, preparing, transferring, finalizing, cancelling, completed, cancelled, failed
    public var isTerminal: Bool { self == .completed || self == .cancelled || self == .failed }
    public var label: String {
        switch self {
        case .queued: "Waiting"
        case .preparing: "Preparing…"
        case .transferring: "Sending…"
        case .finalizing: "Saving to Downloads…"
        case .cancelling: "Cancelling…"
        case .completed: "Saved to Downloads"
        case .cancelled: "Cancelled"
        case .failed: "Couldn't send"
        }
    }
}

public struct FileTransferItem: Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let name: String
    public fileprivate(set) var byteCount: Int64
    public fileprivate(set) var completedBytes: Int64 = 0
    public fileprivate(set) var state: FileTransferState
    public fileprivate(set) var destinationName: String?
    public fileprivate(set) var errorMessage: String?
    public var progress: Double {
        if state == .completed { return 1 }
        return byteCount > 0 ? min(1, Double(completedBytes) / Double(byteCount)) : 0
    }
}

public enum FileTransferError: LocalizedError, Equatable, Sendable {
    case unavailable, regularFilesOnly, unreadable, changedSource, insufficientStorage
    case permissionDenied, interrupted, unsupportedFilesystem, invalidName, tooManyDuplicates
    case helperUnavailable, unsafeStaging, protocolFailure, localStorage, cancellationPending
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Connect to your Pixel before sending files."
        case .regularFilesOnly: "Send regular files from Finder. Folders, aliases, and symbolic links aren't supported."
        case .unreadable: "Nearby couldn't read this file. Check its permissions and try again."
        case .changedSource: "This file changed while it was being sent. Try again when it has finished saving."
        case .insufficientStorage: "Your Pixel doesn't have enough free storage. Free some space, then retry this file."
        case .permissionDenied: "Your Pixel couldn't write to Downloads. Unlock it and check storage access, then retry."
        case .interrupted: "The connection was interrupted. Reconnect, then retry. If saving had already started, check Downloads first."
        case .unsupportedFilesystem: "Downloads doesn't support safe file saving. Nearby stopped to protect existing files."
        case .invalidName: "Your Pixel couldn't use this file name. Rename the file in Finder and try again."
        case .tooManyDuplicates: "Downloads already has too many files with this name. Rename the file and try again."
        case .helperUnavailable: "Nearby's safe file transfer tool is missing or isn't compatible with this Pixel. Rebuild or update Nearby."
        case .unsafeStaging: "Nearby couldn't verify its temporary transfer folder. Existing phone files were left untouched."
        case .protocolFailure: "Your Pixel couldn't finish this transfer. Reconnect and retry."
        case .localStorage: "Nearby couldn't record this transfer safely on your Mac. Check available Mac storage and try again."
        case .cancellationPending: "Nearby is finishing cancellation. Retry this file when cancellation has finished."
        }
    }

    static func fromRemote(_ diagnostic: String) -> FileTransferError {
        let text = diagnostic.lowercased()
        if text.contains("no space") || text.contains("quota exceeded") || text.contains("enospc") { return .insufficientStorage }
        if text.contains("permission denied") || text.contains("read-only") { return .permissionDenied }
        return .interrupted
    }
}

/// Tokens are persisted before remote work starts. Cleanup requires the matching
/// remote ownership marker and never scans, recursively removes, or touches a final file.
struct FileTransferOwnership: Codable, Equatable, Sendable {
    let token: UUID
    let deviceID: String
    var stageName: String { ".nearby-transfer-" + token.uuidString.lowercased() }
    var remotePayload: String { "/sdcard/Download/\(stageName)/payload.partial" }
    var remoteHelper: String { "/data/local/tmp/nearby-transfer-" + token.uuidString.lowercased() }
}

struct FileTransferSource: Sendable {
    let url: URL
    let name: String
    let byteCount: Int64

    init(url: URL) throws {
        guard url.isFileURL else { throw FileTransferError.regularFilesOnly }
        if (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true {
            throw FileTransferError.regularFilesOnly
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? FileTransferError.regularFilesOnly : FileTransferError.unreadable
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw FileTransferError.unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw FileTransferError.regularFilesOnly }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else {
            throw FileTransferError.invalidName
        }
        self.url = url; self.name = name; byteCount = info.st_size
    }
}

protocol FileTransferTransport: Sendable {
    func prepare(_ ownership: FileTransferOwnership, byteCount: Int64) async throws
    func upload(_ source: FileTransferSource, ownership: FileTransferOwnership,
                progress: @escaping @Sendable (Int64) -> Void) async throws
    func commit(_ ownership: FileTransferOwnership, preferredName: String, byteCount: Int64) async throws -> String
    func cleanup(_ ownership: FileTransferOwnership) async throws
}

/// The queue is bound to one explicitly active mirror session. A reconnect never
/// restarts a failed transfer: retry is a separate user action for each file.
@MainActor
public final class FileTransferCoordinator: ObservableObject {
    @Published public private(set) var items: [FileTransferItem] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var isCancelling = false
    @Published public private(set) var cleanupPending = false
    public var canAcceptFiles: Bool { session != nil && transport != nil && !isCancelling }
    private var session: FileTransferSession?
    private var transport: (any FileTransferTransport)?
    private var adb: ADBClient?
    private var worker: Task<Void, Never>?
    private var sessionTransition = UUID()
    private var isTransitioningSession = false
    private var cancellationWasManual = false
    private var pendingCleanup: [FileTransferOwnership]
    private var activeOwnershipToken: UUID?
    private let journalURL: URL
    private let uploadPacing: UploadPacing
    private let makeTransport: @Sendable (FileTransferSession, ADBClient?) throws -> any FileTransferTransport

    /// Source-byte budget shared by the active and queued file uploads. The
    /// default leaves headroom for video and control on the same ADB connection.
    public var uploadRateLimit: Int? { uploadPacing.bytesPerSecond }

    public convenience init(helperURL: URL, cleanupStoreURL: URL? = nil) {
        let journal = cleanupStoreURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nearby/transfer-cleanup.json")
        let pacing = UploadPacing(bytesPerSecond: 500_000)
        self.init(journalURL: journal, uploadPacing: pacing) { session, adb in
            guard let adb, adb.serverPort != nil else { throw FileTransferError.unavailable }
            return ADBFileTransferTransport(adb: adb, serial: session.serial, helperURL: helperURL, uploadPacing: pacing)
        }
    }

    init(journalURL: URL, uploadPacing: UploadPacing = UploadPacing(bytesPerSecond: 500_000),
         makeTransport: @escaping @Sendable (FileTransferSession, ADBClient?) throws -> any FileTransferTransport) {
        self.journalURL = journalURL; self.uploadPacing = uploadPacing; self.makeTransport = makeTransport
        pendingCleanup = (try? Data(contentsOf: journalURL)).flatMap { try? JSONDecoder().decode([FileTransferOwnership].self, from: $0) } ?? []
        cleanupPending = !pendingCleanup.isEmpty
    }

    /// Updates in-flight DATA pacing within 100 ms. nil removes the rate limit;
    /// nonpositive values are clamped to one byte per second. Handshake, DONE,
    /// ownership cleanup, and atomic finalization are never paced.
    public func setUploadRateLimit(bytesPerSecond: Int?) {
        uploadPacing.setRateLimit(bytesPerSecond: bytesPerSecond)
    }

    /// Await before stopping the old owned ADB service. Finalization is short and
    /// deliberately finishes its atomic commit even if Cancel arrives during it.
    public func setSession(_ next: FileTransferSession?, adb nextADB: ADBClient?) async {
        if !isTransitioningSession, next == session, nextADB === adb { return }
        let transition = UUID(); sessionTransition = transition
        isTransitioningSession = true
        defer { if sessionTransition == transition { isTransitioningSession = false } }
        session = nil; transport = nil
        cancellationWasManual = false
        worker?.cancel()
        let previous = worker
        if let previous { await previous.value }
        guard sessionTransition == transition else { return }
        worker = nil
        for index in items.indices where !items[index].state.isTerminal {
            items[index].state = .failed; items[index].errorMessage = FileTransferError.interrupted.localizedDescription
        }
        adb = nextADB
        guard let next else { return }
        do {
            let newTransport = try makeTransport(next, nextADB)
            // Use the newly resolved endpoint only after the app has verified the
            // same paired physical device identity. No payload is resumed here.
            await cleanup(for: next.deviceID, transport: newTransport)
            guard sessionTransition == transition else { return }
            session = next; transport = newTransport
        } catch {
            if sessionTransition == transition { session = nil; transport = nil }
        }
    }

    public func enqueue(_ urls: [URL]) {
        for url in urls {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            do {
                let source = try FileTransferSource(url: url)
                let available = canAcceptFiles
                items.append(FileTransferItem(id: UUID(), sourceURL: url, name: source.name, byteCount: source.byteCount,
                                              state: available ? .queued : .failed,
                                              errorMessage: available ? nil : (isCancelling ? FileTransferError.cancellationPending : .unavailable).localizedDescription))
            } catch {
                items.append(FileTransferItem(id: UUID(), sourceURL: url, name: url.lastPathComponent, byteCount: 0,
                                              state: .failed, errorMessage: error.localizedDescription))
            }
        }
        startWorkerIfNeeded()
    }

    public func retry(_ id: UUID) {
        guard canAcceptFiles, let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .failed || items[index].state == .cancelled else { return }
        items[index].state = .queued; items[index].completedBytes = 0
        items[index].destinationName = nil; items[index].errorMessage = nil
        startWorkerIfNeeded()
    }

    public func cancel() {
        cancellationWasManual = true
        isCancelling = worker != nil
        for index in items.indices where !items[index].state.isTerminal {
            if items[index].state == .queued { items[index].state = .cancelled }
            else if items[index].state != .finalizing { items[index].state = .cancelling }
        }
        worker?.cancel()
    }

    public func dismissFinished() { items.removeAll { $0.state.isTerminal } }

    private func startWorkerIfNeeded() {
        guard worker == nil, let session, let transport, items.contains(where: { $0.state == .queued }) else { return }
        cancellationWasManual = false; isRunning = true
        worker = Task { [weak self] in
            guard let self else { return }
            await run(session: session, transport: transport)
            isRunning = false; isCancelling = false; worker = nil
            startWorkerIfNeeded()
        }
    }

    private func run(session active: FileTransferSession, transport: any FileTransferTransport) async {
        while !Task.isCancelled, session == active, let item = items.first(where: { $0.state == .queued }) {
            let ownership = FileTransferOwnership(token: UUID(), deviceID: active.deviceID)
            activeOwnershipToken = ownership.token
            let granted = item.sourceURL.startAccessingSecurityScopedResource()
            do {
                let source = try FileTransferSource(url: item.sourceURL)
                update(item.id) { $0.byteCount = source.byteCount; $0.state = .preparing }
                // If the reply is lost after prepare, the persisted token still
                // permits marker-verified cleanup after the next connection.
                pendingCleanup.append(ownership)
                do { try writeCleanupJournal() }
                catch {
                    pendingCleanup.removeAll { $0 == ownership }
                    cleanupPending = !pendingCleanup.isEmpty
                    throw FileTransferError.localStorage
                }
                try await transport.prepare(ownership, byteCount: source.byteCount)
                try Task.checkCancellation()
                update(item.id) { $0.state = .transferring }
                try await transport.upload(source, ownership: ownership) { [weak self] bytes in
                    Task { @MainActor [weak self] in
                        self?.update(item.id) {
                            if $0.state == .transferring { $0.completedBytes = max($0.completedBytes, min(source.byteCount, bytes)) }
                        }
                    }
                }
                try Task.checkCancellation()
                update(item.id) { $0.completedBytes = source.byteCount; $0.state = .finalizing }
                // Once commit starts, cancellation finishes that one bounded
                // operation. A successful atomic commit is reported as success.
                let finalName = try await Task.detached(priority: .userInitiated) {
                    try await transport.commit(ownership, preferredName: source.name, byteCount: source.byteCount)
                }.value
                update(item.id) { $0.state = .completed; $0.destinationName = finalName; $0.errorMessage = nil }
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                update(item.id) {
                    $0.state = cancelled && cancellationWasManual ? .cancelled : .failed
                    $0.errorMessage = cancelled ? (cancellationWasManual ? nil : FileTransferError.interrupted.localizedDescription) : error.localizedDescription
                }
            }
            if granted { item.sourceURL.stopAccessingSecurityScopedResource() }
            if pendingCleanup.contains(ownership) { await cleanupOne(ownership, transport: transport) }
            activeOwnershipToken = nil
            cleanupPending = !pendingCleanup.isEmpty
            if Task.isCancelled || session != active { break }
            if items.first(where: { $0.id == item.id })?.errorMessage == FileTransferError.interrupted.localizedDescription {
                // A broken endpoint must not cause the remaining queue to fail
                // one request at a time or forward through a replacement session.
                for index in items.indices where items[index].state == .queued {
                    items[index].state = .failed; items[index].errorMessage = FileTransferError.interrupted.localizedDescription
                }
                break
            }
        }
        if Task.isCancelled {
            for index in items.indices where !items[index].state.isTerminal {
                items[index].state = cancellationWasManual ? .cancelled : .failed
                items[index].errorMessage = cancellationWasManual ? nil : FileTransferError.interrupted.localizedDescription
            }
        }
    }

    private func update(_ id: UUID, _ body: (inout FileTransferItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    private func cleanup(for deviceID: String, transport: any FileTransferTransport) async {
        for ownership in pendingCleanup where ownership.deviceID == deviceID {
            await cleanupOne(ownership, transport: transport)
        }
    }

    private func cleanupOne(_ ownership: FileTransferOwnership, transport: any FileTransferTransport) async {
        let cleaned = await Task.detached(priority: .utility) {
            do { try await transport.cleanup(ownership); return true } catch { return false }
        }.value
        if cleaned { pendingCleanup.removeAll { $0 == ownership } }
        persistCleanup()
    }

    private func persistCleanup() {
        cleanupPending = pendingCleanup.contains { $0.token != activeOwnershipToken }
        try? writeCleanupJournal()
    }

    private func writeCleanupJournal() throws {
        cleanupPending = pendingCleanup.contains { $0.token != activeOwnershipToken }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pendingCleanup)
        try data.write(to: journalURL, options: .atomic)
        // Atomic replacement writes a new inode, so restore private permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
}

struct ADBFileTransferTransport: FileTransferTransport {
    let adb: ADBClient
    let serial: String
    let helperURL: URL
    let uploadPacing: UploadPacing

    func prepare(_ ownership: FileTransferOwnership, byteCount: Int64) async throws {
        try await installHelper(ownership)
        _ = try await invoke(ownership, arguments: ["prepare", ownership.token.uuidString.lowercased(), String(byteCount)])
    }

    func upload(_ source: FileTransferSource, ownership: FileTransferOwnership,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let port = adb.serverPort, port != 5037 else { throw FileTransferError.unavailable }
        let upload = ADBSyncUpload(port: port, serial: serial, source: source, remotePath: ownership.remotePayload,
                                   pacing: uploadPacing, progress: progress)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await upload.run()
        } onCancel: { upload.cancel() }
    }

    func commit(_ ownership: FileTransferOwnership, preferredName: String, byteCount: Int64) async throws -> String {
        let response = try await invoke(ownership, arguments: ["commit", ownership.token.uuidString.lowercased(), preferredName, String(byteCount)])
        guard response.hasPrefix("OK\t") else { throw FileTransferError.protocolFailure }
        let name = String(response.dropFirst(3))
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else { throw FileTransferError.protocolFailure }
        return name
    }

    func cleanup(_ ownership: FileTransferOwnership) async throws {
        // Reinstalling permits cleanup after a process/network interruption. Only
        // the exact token path is used, and cleanup verifies the remote marker.
        try await installHelper(ownership, timeout: 4)
        _ = try await invoke(ownership, arguments: ["cleanup", ownership.token.uuidString.lowercased()], timeout: 4)
        let command = "rm -f -- " + Self.quote(ownership.remoteHelper)
        let result = try await adb.run(["-s", serial, "shell", "-T", command], timeout: 4)
        guard result.status == 0 else { throw FileTransferError.interrupted }
    }

    private func installHelper(_ ownership: FileTransferOwnership, timeout: TimeInterval = 12) async throws {
        guard adb.serverPort != nil, adb.serverPort != 5037,
              FileManager.default.isReadableFile(atPath: helperURL.path) else { throw FileTransferError.helperUnavailable }
        let abi = try await adb.run(["-s", serial, "shell", "getprop", "ro.product.cpu.abi"], timeout: timeout)
        guard abi.status == 0 else { throw FileTransferError.interrupted }
        let architecture = abi.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard architecture == "arm64-v8a" || architecture == "x86_64" else { throw FileTransferError.helperUnavailable }
        let selectedHelper = helperURL.deletingLastPathComponent().appendingPathComponent("nearby-transfer-" + architecture)
        guard FileManager.default.isReadableFile(atPath: selectedHelper.path) else { throw FileTransferError.helperUnavailable }
        let result = try await adb.run(["-s", serial, "push", "-q", selectedHelper.path, ownership.remoteHelper], timeout: timeout)
        guard result.status == 0 else { throw FileTransferError.fromRemote(result.stderr + result.stdout) }
        let chmod = try await adb.run(["-s", serial, "shell", "-T", "chmod 700 " + Self.quote(ownership.remoteHelper)], timeout: timeout)
        guard chmod.status == 0 else { throw FileTransferError.helperUnavailable }
    }

    private func invoke(_ ownership: FileTransferOwnership, arguments: [String], timeout: TimeInterval = 12) async throws -> String {
        let command = ([ownership.remoteHelper] + arguments).map(Self.quote).joined(separator: " ")
        let response: CommandOutput
        do { response = try await adb.run(["-s", serial, "shell", "-T", command], timeout: timeout) }
        catch is CancellationError { throw CancellationError() }
        catch { throw FileTransferError.interrupted }
        guard response.status == 0 else {
            switch response.status {
            case 21: throw FileTransferError.insufficientStorage
            case 22: throw FileTransferError.permissionDenied
            case 23: throw FileTransferError.unsupportedFilesystem
            case 24: throw FileTransferError.invalidName
            case 25: throw FileTransferError.tooManyDuplicates
            case 26: throw FileTransferError.unsafeStaging
            case 27: throw FileTransferError.changedSource
            case 28: throw FileTransferError.protocolFailure
            case 126, 127: throw FileTransferError.helperUnavailable
            default: throw FileTransferError.fromRemote(response.stderr)
            }
        }
        return response.stdout
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

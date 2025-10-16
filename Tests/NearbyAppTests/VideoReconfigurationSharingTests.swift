import AppKit
import XCTest
@testable import NearbyCore
@testable import Nearby

/// Records the synchronous transport factory without introducing a real ADB
/// client. Rebinding the coordinator would be visible even with the same mock.
private final class ReconfigurationTransferBindings: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [FileTransferSession] = []

    func record(_ session: FileTransferSession) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(session)
    }

    var sessions: [FileTransferSession] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

private actor ReconfigurationFileTransport: FileTransferTransport {
    struct Snapshot: Sendable {
        var prepared: [FileTransferOwnership]
        var uploaded: [FileTransferOwnership]
        var committed: [FileTransferOwnership]
        var cleaned: [FileTransferOwnership]
        var cancellations: Int
    }

    private var prepared: [FileTransferOwnership] = []
    private var uploaded: [FileTransferOwnership] = []
    private var committed: [FileTransferOwnership] = []
    private var cleaned: [FileTransferOwnership] = []
    private var cancellations = 0
    private var released = false
    private var pendingUpload: CheckedContinuation<Void, Error>?

    func snapshot() -> Snapshot {
        Snapshot(prepared: prepared, uploaded: uploaded, committed: committed,
                 cleaned: cleaned, cancellations: cancellations)
    }

    func prepare(_ ownership: FileTransferOwnership, byteCount: Int64) async throws {
        prepared.append(ownership)
    }

    func upload(_ source: FileTransferSource, ownership: FileTransferOwnership,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
        uploaded.append(ownership)
        progress(source.byteCount / 2)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    if released { continuation.resume() }
                    else { pendingUpload = continuation }
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.cancelPendingUpload() }
            }
        } catch {
            if error is CancellationError { cancellations += 1 }
            throw error
        }
        progress(source.byteCount)
    }

    private func cancelPendingUpload() {
        let continuation = pendingUpload
        pendingUpload = nil
        continuation?.resume(throwing: CancellationError())
    }

    func releaseUpload() {
        released = true
        let continuation = pendingUpload
        pendingUpload = nil
        continuation?.resume()
    }

    func commit(_ ownership: FileTransferOwnership, preferredName: String, byteCount: Int64) async throws -> String {
        committed.append(ownership)
        return preferredName
    }

    func cleanup(_ ownership: FileTransferOwnership) async throws {
        cleaned.append(ownership)
    }
}

@MainActor
private final class ReconfigurationClipboardTransport: ClipboardSessionTransport {
    struct Request {
        let id: UUID
        let text: String
        let paste: Bool
    }

    var isStreaming = true
    var onClipboard: ((String) -> Void)?
    private(set) var requests: [Request] = []
    private(set) var cancellationCount = 0
    var resumesWhenCancelled = true
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]

    func sendClipboard(_ text: String, paste: Bool, timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        let request = Request(id: UUID(), text: text, paste: paste)
        try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            requests.append(request)
        }
    }

    func cancelClipboardTransfers() {
        cancellationCount += 1
        if resumesWhenCancelled { finishAll(throwing: CancellationError()) }
    }

    func finish(_ request: Request) {
        pending.removeValue(forKey: request.id)?.resume()
    }

    func finishAll(throwing error: Error) {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }
}

/// Lifecycle tests use only named pasteboards, temporary regular files and
/// gated transports. No AppModel, preferences, device or ADB service is created.
@MainActor
final class VideoReconfigurationSharingTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let source: URL
        let journal: URL
        let binding: FileTransferSession
        let bindings: ReconfigurationTransferBindings
        let fileTransport: ReconfigurationFileTransport
        let transfers: FileTransferCoordinator
        let pasteboard: NSPasteboard
        let engine: ReconfigurationClipboardTransport
        let sharing: SessionSharingModel
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NearbyVideoReconfigurationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Nearby harmless test sample.txt")
        try Data("Nearby harmless test file.\n".utf8).write(to: source)
        let journal = root.appendingPathComponent("cleanup.json")
        let bindings = ReconfigurationTransferBindings()
        let fileTransport = ReconfigurationFileTransport()
        let transfers = FileTransferCoordinator(journalURL: journal) { session, _ in
            bindings.record(session)
            return fileTransport
        }
        let binding = FileTransferSession(id: UUID(), deviceID: "test-paired-pixel", serial: "test-endpoint:5555")
        await transfers.setSession(binding, adb: nil)

        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(pasteboard.replaceText("Nearby initial test clipboard"))
        let engine = ReconfigurationClipboardTransport()
        let sharing = SessionSharingModel(pasteboard: pasteboard, foreground: { true },
                                         sharingEnabled: { true }, observesApplication: false,
                                         transfers: transfers)
        sharing.configure(model: nil, engine: engine, generation: UUID())
        sharing.becameActive()
        addTeardownBlock { @MainActor in
            await fileTransport.releaseUpload()
            await sharing.stopAndWait()
            engine.finishAll(throwing: CancellationError())
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, source: source, journal: journal, binding: binding,
                       bindings: bindings, fileTransport: fileTransport, transfers: transfers,
                       pasteboard: pasteboard, engine: engine, sharing: sharing)
    }

    private func expect(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                        _ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(description, file: file, line: line)
        return false
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    func testVideoPauseAndResumePreserveInFlightUploadAndOriginalBinding() async throws {
        let fixture = try await fixture()
        fixture.sharing.acceptFiles([fixture.source])
        guard await expect("The gated upload did not start", {
            await fixture.fileTransport.snapshot().uploaded.count == 1
        }) else { return }
        let initial = await fixture.fileTransport.snapshot()
        let ownership = try XCTUnwrap(initial.uploaded.first)
        XCTAssertEqual(fixture.transfers.items.first?.state, .transferring)
        XCTAssertTrue(fixture.sharing.transfers === fixture.transfers)

        fixture.sharing.pauseForVideoReconfiguration()
        fixture.engine.isStreaming = false
        fixture.sharing.refreshContext()
        XCTAssertFalse(fixture.sharing.canSend)
        await settle()
        let paused = await fixture.fileTransport.snapshot()
        XCTAssertEqual(paused.cancellations, 0)
        XCTAssertTrue(paused.committed.isEmpty)
        XCTAssertTrue(paused.cleaned.isEmpty, "Video-only pause must not clean a live file's ownership token")
        XCTAssertTrue(fixture.transfers.isRunning)
        XCTAssertTrue(fixture.transfers.canAcceptFiles)
        XCTAssertEqual(fixture.transfers.items.first?.state, .transferring)
        XCTAssertEqual(fixture.bindings.sessions, [fixture.binding])
        XCTAssertEqual(try JSONDecoder().decode([FileTransferOwnership].self,
                                               from: Data(contentsOf: fixture.journal)), [ownership])

        fixture.engine.isStreaming = true
        fixture.sharing.resumeAfterVideoReconfiguration()
        await settle()
        let resumed = await fixture.fileTransport.snapshot()
        XCTAssertTrue(fixture.sharing.canSend)
        XCTAssertEqual(resumed.cancellations, 0)
        XCTAssertTrue(resumed.cleaned.isEmpty)
        XCTAssertEqual(fixture.bindings.sessions, [fixture.binding], "Resume must retain the verified transfer binding")

        await fixture.fileTransport.releaseUpload()
        guard await expect("The released upload did not finish", { !fixture.transfers.isRunning }) else { return }
        let completed = await fixture.fileTransport.snapshot()
        XCTAssertEqual(fixture.transfers.items.first?.state, .completed)
        XCTAssertEqual(completed.prepared, [ownership])
        XCTAssertEqual(completed.uploaded, [ownership])
        XCTAssertEqual(completed.committed, [ownership])
        XCTAssertEqual(completed.cleaned, [ownership])
        XCTAssertEqual(completed.cancellations, 0)
        XCTAssertEqual(fixture.bindings.sessions, [fixture.binding])
        XCTAssertEqual(try JSONDecoder().decode([FileTransferOwnership].self,
                                               from: Data(contentsOf: fixture.journal)), [])
    }

    func testBecomingInactiveCancelsUploadAndCleansItsOwnedToken() async throws {
        let fixture = try await fixture()
        fixture.sharing.acceptFiles([fixture.source])
        guard await expect("The gated upload did not start", {
            await fixture.fileTransport.snapshot().uploaded.count == 1
        }) else { return }
        let initial = await fixture.fileTransport.snapshot()
        let ownership = try XCTUnwrap(initial.uploaded.first)

        fixture.sharing.becameInactive()
        guard await expect("Inactive sharing did not cancel its file upload", { !fixture.transfers.isRunning }) else { return }
        let stopped = await fixture.fileTransport.snapshot()
        XCTAssertEqual(stopped.cancellations, 1)
        XCTAssertTrue(stopped.committed.isEmpty)
        XCTAssertEqual(stopped.cleaned, [ownership])
        XCTAssertEqual(fixture.transfers.items.first?.state, .failed)
        XCTAssertEqual(fixture.transfers.items.first?.errorMessage, FileTransferError.interrupted.localizedDescription)
        XCTAssertFalse(fixture.transfers.canAcceptFiles)
        XCTAssertEqual(fixture.bindings.sessions, [fixture.binding])
        XCTAssertEqual(try JSONDecoder().decode([FileTransferOwnership].self,
                                               from: Data(contentsOf: fixture.journal)), [])
    }

    func testVideoPauseCancelsPendingClipboardAndResumeSkipsPausedCopyAndLateAck() async throws {
        let fixture = try await fixture()
        fixture.engine.resumesWhenCancelled = false
        XCTAssertTrue(fixture.pasteboard.replaceText("Nearby before video restart"))
        fixture.sharing.pollClipboard()
        guard await expect("The first clipboard send did not start", { fixture.engine.requests.count == 1 }) else { return }
        let oldRequest = fixture.engine.requests[0]
        XCTAssertEqual(fixture.sharing.clipboardStatus, .sending)

        fixture.sharing.pauseForVideoReconfiguration()
        XCTAssertEqual(fixture.engine.cancellationCount, 1)
        XCTAssertFalse(fixture.sharing.isSendingText)
        XCTAssertFalse(fixture.sharing.canSend)
        fixture.engine.isStreaming = false
        XCTAssertTrue(fixture.pasteboard.replaceText("Nearby copied during video restart"))
        fixture.sharing.pollClipboard()
        fixture.engine.onClipboard?("Nearby ignored remote copy during video restart")
        XCTAssertEqual(fixture.pasteboard.readText(), "Nearby copied during video restart")

        fixture.engine.isStreaming = true
        fixture.sharing.resumeAfterVideoReconfiguration()
        fixture.sharing.pollClipboard()
        await settle()
        XCTAssertEqual(fixture.engine.requests.count, 1, "Resume must not replay a copy made while video was paused")
        XCTAssertEqual(fixture.sharing.clipboardStatus, .ready)

        XCTAssertTrue(fixture.pasteboard.replaceText("Nearby fresh post-restart copy नमस्ते"))
        fixture.sharing.pollClipboard()
        guard await expect("The fresh post-resume clipboard send did not start", { fixture.engine.requests.count == 2 }) else { return }
        let freshRequest = fixture.engine.requests[1]
        XCTAssertEqual(freshRequest.text, "Nearby fresh post-restart copy नमस्ते")
        XCTAssertFalse(freshRequest.paste)
        fixture.engine.finish(oldRequest)
        await settle()
        XCTAssertEqual(fixture.sharing.clipboardStatus, .sending, "An old acknowledgement cannot complete the new send")
        XCTAssertTrue(fixture.sharing.isSendingText)
        XCTAssertNil(fixture.sharing.pasteMessage)

        fixture.engine.finish(freshRequest)
        guard await expect("The current clipboard acknowledgement did not complete", {
            fixture.sharing.clipboardStatus == .ready && !fixture.sharing.isSendingText
        }) else { return }
        XCTAssertEqual(fixture.engine.requests.count, 2)
    }
}

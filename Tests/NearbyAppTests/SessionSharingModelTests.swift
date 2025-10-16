import AppKit
import XCTest
import NearbyCore
@testable import Nearby

@MainActor
private final class ClipboardEnvironment {
    var foreground = true
    var sharingEnabled = true
}

/// Only harmless, app-owned test text reaches this controllable transport.
/// Ignoring cancellation in one test simulates an already-running late reply.
@MainActor
private final class TestClipboardTransport: ClipboardSessionTransport {
    struct Request {
        let id: UUID
        let text: String
        let paste: Bool
        let timeout: TimeInterval
    }
    var isStreaming = true
    var onClipboard: ((String) -> Void)?
    private(set) var requests: [Request] = []
    private(set) var cancellationCount = 0
    var resumesWhenCancelled = true
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]

    func sendClipboard(_ text: String, paste: Bool, timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        let request = Request(id: UUID(), text: text, paste: paste, timeout: timeout)
        try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            requests.append(request)
        }
    }

    func cancelClipboardTransfers() {
        cancellationCount += 1
        if resumesWhenCancelled { finishAll(throwing: CancellationError()) }
    }

    func finish(_ request: Request, throwing error: Error? = nil) {
        guard let continuation = pending.removeValue(forKey: request.id) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func finishAll(throwing error: Error? = nil) {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations {
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
}

@MainActor
private final class FallibleNativePasteboard: TextPasteboard {
    let native: NSPasteboard
    var failsWrites = false
    init(_ native: NSPasteboard) { self.native = native }
    var changeCount: Int { native.changeCount }
    func readText() -> String? { native.readText() }
    func replaceText(_ text: String) -> Bool { !failsWrites && native.replaceText(text) }
}

/// Exercises the actual native sharing owner against isolated, named macOS
/// pasteboards. It never reads general, constructs AppModel, starts ADB, changes
/// focus, touches preferences, or registers login/runtime services.
@MainActor
final class SessionSharingModelTests: XCTestCase {
    private struct Fixture {
        let pasteboard: NSPasteboard
        let environment: ClipboardEnvironment
        let engine: TestClipboardTransport
        let sharing: SessionSharingModel
    }

    private func fixture(foreground: Bool = true, sharingEnabled: Bool = true) -> Fixture {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.replaceText("Nearby initial sample")
        let environment = ClipboardEnvironment()
        environment.foreground = foreground
        environment.sharingEnabled = sharingEnabled
        let engine = TestClipboardTransport()
        let sharing = SessionSharingModel(pasteboard: pasteboard,
                                         foreground: { environment.foreground },
                                         sharingEnabled: { environment.sharingEnabled }, observesApplication: false)
        sharing.configure(model: nil, engine: engine, generation: UUID())
        sharing.becameActive()
        return Fixture(pasteboard: pasteboard, environment: environment, engine: engine, sharing: sharing)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func expectRequests(_ count: Int, from engine: TestClipboardTransport,
                                file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        for _ in 0..<500 {
            if engine.requests.count >= count { return true }
            await Task.yield()
        }
        XCTFail("The expected clipboard transport request did not start", file: file, line: line)
        return false
    }

    private func stop(_ fixture: Fixture) async {
        await fixture.sharing.stopAndWait()
        fixture.engine.finishAll(throwing: CancellationError())
        fixture.pasteboard.clearContents()
        fixture.pasteboard.releaseGlobally()
        await settle()
    }

    func testBackgroundRemoteTextIsIgnoredAndPendingPasteIsCancelled() async {
        let fixture = fixture()
        fixture.pasteboard.replaceText("Nearby foreground paste sample")
        fixture.sharing.pasteToPixel()
        guard await expectRequests(1, from: fixture.engine) else { await stop(fixture); return }
        XCTAssertEqual(fixture.sharing.clipboardStatus, .sending)
        fixture.environment.foreground = false
        fixture.sharing.refreshContext()
        XCTAssertEqual(fixture.sharing.clipboardStatus, .paused)
        XCTAssertEqual(fixture.engine.cancellationCount, 1)
        fixture.engine.onClipboard?("Nearby background remote sample")
        XCTAssertEqual(fixture.pasteboard.readText(), "Nearby foreground paste sample")
        fixture.sharing.pollClipboard()
        await settle()
        XCTAssertEqual(fixture.engine.requests.count, 1)
        XCTAssertNil(fixture.sharing.pasteMessage, "A cancelled completion must not publish stale feedback")
        await stop(fixture)
    }

    func testActivationSkipsBackgroundCopiesAndRemoteWritesNeverLoop() async {
        let fixture = fixture(foreground: false)
        fixture.pasteboard.replaceText("Nearby background local sample")
        fixture.sharing.pollClipboard()
        fixture.environment.foreground = true
        fixture.sharing.refreshContext()
        fixture.sharing.pollClipboard()
        await settle()
        XCTAssertTrue(fixture.engine.requests.isEmpty, "Activation must not replay text copied outside the mirror")
        fixture.pasteboard.replaceText("Nearby fresh Unicode नमस्ते 🪷")
        fixture.sharing.pollClipboard()
        guard await expectRequests(1, from: fixture.engine) else { await stop(fixture); return }
        XCTAssertFalse(fixture.engine.requests[0].paste)
        fixture.engine.finish(fixture.engine.requests[0])
        await settle()
        fixture.engine.onClipboard?("Nearby Pixel copy こんにちは 😀")
        XCTAssertEqual(fixture.pasteboard.readText(), "Nearby Pixel copy こんにちは 😀")
        fixture.sharing.pollClipboard()
        await settle()
        XCTAssertEqual(fixture.engine.requests.count, 1, "Writing a remote copy to the Mac must not echo it back")
        await stop(fixture)
    }

    func testDisablingSharingCancelsAutomaticSendAndDoesNotReplayWhenEnabled() async {
        let fixture = fixture()
        fixture.pasteboard.replaceText("Nearby automatic sample")
        fixture.sharing.pollClipboard()
        guard await expectRequests(1, from: fixture.engine) else { await stop(fixture); return }
        XCTAssertFalse(fixture.engine.requests[0].paste)
        fixture.environment.sharingEnabled = false
        fixture.sharing.refreshContext()
        XCTAssertEqual(fixture.engine.cancellationCount, 1)
        XCTAssertEqual(fixture.sharing.clipboardStatus, .disabled)
        fixture.engine.onClipboard?("Nearby ignored disabled remote sample")
        XCTAssertEqual(fixture.pasteboard.readText(), "Nearby automatic sample")
        fixture.pasteboard.replaceText("Nearby copied while disabled sample")
        fixture.sharing.pollClipboard()
        fixture.environment.sharingEnabled = true
        fixture.sharing.refreshContext()
        fixture.sharing.pollClipboard()
        await settle()
        XCTAssertEqual(fixture.engine.requests.count, 1)
        fixture.pasteboard.replaceText("Nearby fresh enabled sample")
        fixture.sharing.pollClipboard()
        guard await expectRequests(2, from: fixture.engine) else { await stop(fixture); return }
        await stop(fixture)
    }

    func testReplacementRejectsOldRemoteCallbackAndLateCompletion() async {
        let fixture = fixture()
        fixture.engine.resumesWhenCancelled = false
        fixture.pasteboard.replaceText("Nearby old session sample")
        fixture.sharing.pasteToPixel()
        guard await expectRequests(1, from: fixture.engine) else { await stop(fixture); return }
        let oldCallback = fixture.engine.onClipboard
        let replacement = TestClipboardTransport()
        fixture.sharing.configure(model: nil, engine: replacement, generation: UUID())
        XCTAssertEqual(fixture.engine.cancellationCount, 1)
        oldCallback?("Nearby stale remote sample")
        XCTAssertEqual(fixture.pasteboard.readText(), "Nearby old session sample")
        fixture.pasteboard.replaceText("Nearby replacement sample")
        fixture.sharing.pasteToPixel()
        guard await expectRequests(1, from: replacement) else {
            await stop(fixture); replacement.finishAll(throwing: CancellationError()); return
        }
        fixture.engine.finish(fixture.engine.requests[0])
        await settle()
        XCTAssertEqual(fixture.sharing.clipboardStatus, .sending)
        XCTAssertNil(fixture.sharing.pasteMessage)
        replacement.finish(replacement.requests[0], throwing: ClipboardFailure.timedOut)
        await settle()
        XCTAssertEqual(fixture.sharing.clipboardStatus, .failed(.timedOut))
        XCTAssertTrue(fixture.sharing.pasteFailed)
        await stop(fixture)
        replacement.finishAll(throwing: CancellationError())
    }

    func testRetryPreservesExplicitPasteWhileAutomaticSharingIsOff() async {
        let fixture = fixture(sharingEnabled: false)
        let sample = "Nearby retry नमस्ते こんにちは مرحبا 🪷"
        fixture.pasteboard.replaceText(sample)
        fixture.sharing.pasteToPixel()
        guard await expectRequests(1, from: fixture.engine) else { await stop(fixture); return }
        XCTAssertTrue(fixture.engine.requests[0].paste)
        fixture.engine.finish(fixture.engine.requests[0], throwing: ClipboardFailure.timedOut)
        await settle()
        XCTAssertTrue(fixture.sharing.pasteFailed)
        XCTAssertEqual(fixture.sharing.clipboardStatus, .disabled)
        fixture.sharing.retryClipboard()
        guard await expectRequests(2, from: fixture.engine) else { await stop(fixture); return }
        XCTAssertTrue(fixture.engine.requests[1].paste, "Retry must preserve the user's explicit Paste action")
        XCTAssertEqual(fixture.engine.requests[1].text, sample)
        XCTAssertEqual(fixture.engine.requests[1].timeout, 3)
        fixture.engine.finish(fixture.engine.requests[1])
        await settle()
        XCTAssertFalse(fixture.sharing.pasteFailed)
        XCTAssertEqual(fixture.sharing.clipboardStatus, .disabled)
        XCTAssertTrue(fixture.sharing.pasteMessage?.hasPrefix("Sent to Pixel.") == true)
        XCTAssertFalse(fixture.sharing.pasteMessage?.contains(sample) == true)
        await stop(fixture)
    }

    func testLocalWriteFailureRecoversOnFreshRemoteCopyAndRetryGivesUsefulAction() async {
        let native = NSPasteboard.withUniqueName()
        native.replaceText("Nearby Mac sample")
        let pasteboard = FallibleNativePasteboard(native)
        let engine = TestClipboardTransport()
        let sharing = SessionSharingModel(pasteboard: pasteboard, foreground: { true }, observesApplication: false)
        sharing.configure(model: nil, engine: engine, generation: UUID())
        pasteboard.failsWrites = true
        engine.onClipboard?("Nearby Pixel sample")
        XCTAssertEqual(sharing.clipboardStatus, .failed(.localWriteFailed))
        XCTAssertEqual(native.readText(), "Nearby Mac sample")
        pasteboard.failsWrites = false
        engine.onClipboard?("Nearby Pixel sample")
        XCTAssertEqual(native.readText(), "Nearby Pixel sample")
        XCTAssertEqual(sharing.clipboardStatus, .ready, "A successful fresh copy must clear a previous local-write failure")
        sharing.pollClipboard()
        await settle()
        XCTAssertTrue(engine.requests.isEmpty)
        pasteboard.failsWrites = true
        engine.onClipboard?("Nearby another Pixel sample")
        XCTAssertEqual(sharing.clipboardStatus, .failed(.localWriteFailed))
        sharing.retryClipboard()
        XCTAssertEqual(sharing.clipboardStatus, .ready)
        XCTAssertEqual(sharing.pasteMessage, "Copy the text again on Pixel while this mirror is active.")
        XCTAssertTrue(engine.requests.isEmpty, "Retrying a Mac write failure must not paste unrelated Mac text into Pixel")
        await sharing.stopAndWait()
        native.clearContents(); native.releaseGlobally()
    }
}

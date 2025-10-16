import XCTest
@testable import NearbyCore

final class ClipboardSyncPolicyTests: XCTestCase {
    private let session = UUID()

    private func ready(changeCount: Int = 4, enabled: Bool = true) -> ClipboardSyncPolicy {
        var policy = ClipboardSyncPolicy()
        policy.configure(sessionID: session, isStreaming: true, isForeground: true,
                         enabled: enabled, pasteboardChangeCount: changeCount)
        return policy
    }

    func testAvailabilityFocusAndPreferenceHaveExplicitStates() {
        var policy = ClipboardSyncPolicy()
        XCTAssertEqual(policy.status, .unavailable)
        policy.configure(sessionID: session, isStreaming: false, isForeground: false, enabled: true, pasteboardChangeCount: 1)
        XCTAssertEqual(policy.status, .unavailable)
        policy.configure(sessionID: session, isStreaming: true, isForeground: false, enabled: true, pasteboardChangeCount: 1)
        XCTAssertEqual(policy.status, .paused)
        policy.configure(sessionID: session, isStreaming: true, isForeground: true, enabled: true, pasteboardChangeCount: 1)
        XCTAssertEqual(policy.status, .ready)
        policy.configure(sessionID: session, isStreaming: true, isForeground: true, enabled: false, pasteboardChangeCount: 1)
        XCTAssertEqual(policy.status, .disabled)
        XCTAssertEqual(try policy.validatePaste("नमस्ते 😀", sessionID: session), "नमस्ते 😀", "Intentional paste is independent of autosync preference")
    }

    func testActivationAndReconnectDoNotReplayBackgroundClipboard() throws {
        var policy = ready()
        XCTAssertNil(try policy.automaticText("existing clipboard", changeCount: 4, sessionID: session))
        XCTAssertEqual(try policy.automaticText("new text", changeCount: 5, sessionID: session), "new text")
        policy.configure(sessionID: session, isStreaming: true, isForeground: false, enabled: true, pasteboardChangeCount: 5)
        XCTAssertNil(try policy.automaticText("private other app text", changeCount: 6, sessionID: session))
        XCTAssertFalse(policy.shouldApplyRemoteText("phone text", sessionID: session))
        policy.configure(sessionID: session, isStreaming: true, isForeground: true, enabled: true, pasteboardChangeCount: 6)
        XCTAssertNil(try policy.automaticText("private other app text", changeCount: 6, sessionID: session))
        policy.configure(sessionID: session, isStreaming: false, isForeground: true, enabled: true, pasteboardChangeCount: 6)
        policy.configure(sessionID: session, isStreaming: true, isForeground: true, enabled: true, pasteboardChangeCount: 8)
        XCTAssertNil(try policy.automaticText("copied while reconnecting", changeCount: 8, sessionID: session))
        XCTAssertEqual(try policy.automaticText("fresh", changeCount: 9, sessionID: session), "fresh")
    }

    func testBothDirectionsIgnoreOldSessionAndSharingDisabled() throws {
        var policy = ready()
        let other = UUID()
        XCTAssertNil(try policy.automaticText("wrong device", changeCount: 7, sessionID: other))
        XCTAssertFalse(policy.shouldApplyRemoteText("wrong device", sessionID: other))
        XCTAssertThrowsError(try policy.validatePaste("text", sessionID: other)) { XCTAssertEqual($0 as? ClipboardFailure, .unavailable) }
        policy.configure(sessionID: session, isStreaming: true, isForeground: true, enabled: false, pasteboardChangeCount: 9)
        XCTAssertNil(try policy.automaticText("text", changeCount: 10, sessionID: session))
        XCTAssertFalse(policy.shouldApplyRemoteText("phone text", sessionID: session))
        policy.configure(sessionID: session, isStreaming: true, isForeground: true, enabled: true, pasteboardChangeCount: 10)
        XCTAssertNil(try policy.automaticText("text", changeCount: 10, sessionID: session))
    }

    func testRemoteWritesAndShortLivedOutgoingEchoesDoNotLoop() throws {
        var policy = ready()
        XCTAssertTrue(policy.shouldApplyRemoteText("phone 😀", sessionID: session))
        policy.remoteWriteCompleted(changeCount: 5, sessionID: session)
        XCTAssertNil(try policy.automaticText("phone 😀", changeCount: 5, sessionID: session))
        policy.sendStarted(text: "Mac 🪷", sessionID: session, now: 100)
        XCTAssertEqual(policy.status, .sending)
        policy.sendSucceeded(sessionID: session)
        XCTAssertFalse(policy.shouldApplyRemoteText("Mac 🪷", sessionID: session, now: 101))
        XCTAssertTrue(policy.shouldApplyRemoteText("Mac 🪷", sessionID: session, currentLocalText: "different", now: 106),
                      "A later intentional copy of identical text must not be suppressed forever")
        XCTAssertFalse(policy.shouldApplyRemoteText("same", sessionID: session, currentLocalText: "same", now: 106))
    }

    func testOversizeAndNonTextAreConsumedAndFailuresCanRecover() throws {
        var policy = ready()
        let oversized = String(repeating: "😀", count: ClipboardTransferLimits.maximumTextBytes / 4 + 1)
        XCTAssertThrowsError(try policy.automaticText(oversized, changeCount: 5, sessionID: session)) {
            XCTAssertEqual($0 as? ClipboardFailure, .tooLarge)
        }
        XCTAssertEqual(policy.status, .failed(.tooLarge))
        XCTAssertNil(try policy.automaticText(oversized, changeCount: 5, sessionID: session))
        XCTAssertNil(try policy.automaticText(nil, changeCount: 6, sessionID: session))
        XCTAssertNil(try policy.automaticText("", changeCount: 7, sessionID: session))
        XCTAssertEqual(try policy.automaticText("small", changeCount: 8, sessionID: session), "small")
        policy.sendStarted(text: "small", sessionID: session)
        policy.sendFailed(.timedOut, sessionID: session)
        XCTAssertEqual(policy.status, .failed(.timedOut))
        policy.clearFailure()
        XCTAssertEqual(policy.status, .ready)
        XCTAssertThrowsError(try policy.validatePaste(oversized, sessionID: session)) { XCTAssertEqual($0 as? ClipboardFailure, .tooLarge) }
        XCTAssertThrowsError(try policy.validatePaste(nil, sessionID: session)) { XCTAssertEqual($0 as? ClipboardFailure, .empty) }
    }

    func testLateOperationResultCannotAffectReplacementSession() {
        var policy = ready()
        policy.sendStarted(text: "sample", sessionID: session)
        let replacement = UUID()
        policy.configure(sessionID: replacement, isStreaming: true, isForeground: true, enabled: true, pasteboardChangeCount: 7)
        policy.sendFailed(.connectionLost, sessionID: session)
        XCTAssertEqual(policy.status, .ready)
        XCTAssertFalse(policy.shouldApplyRemoteText("old session", sessionID: session))
    }
}

import Foundation
import CryptoKit

public enum ClipboardTransferLimits {
    /// scrcpy 3.3.4's 256 KiB control message, less its 14-byte header.
    public static let maximumTextBytes = (1 << 18) - 14
}

/// Deliberately contains no clipboard contents or transport diagnostic output.
public enum ClipboardFailure: Error, LocalizedError, Equatable, Sendable {
    case unavailable, notFocused, empty, tooLarge, busy, timedOut, cancelled, connectionLost, localWriteFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Connect to your Pixel before sending text."
        case .notFocused: "Bring the Pixel mirror to the front to share text."
        case .empty: "Copy some text on your Mac first."
        case .tooLarge: "This text is too large to send. Copy a smaller selection (under 256 KB)."
        case .busy: "Text is already being sent. Try again when it finishes."
        case .timedOut: "Your Pixel did not acknowledge the text. Check the connection and try again."
        case .cancelled: "Sending text was cancelled."
        case .connectionLost: "The connection ended before text could be sent. Try again after reconnecting."
        case .localWriteFailed: "The Mac clipboard could not be updated. Try copying the text again."
        }
    }
}

public enum ClipboardSharingStatus: Equatable, Sendable {
    case disabled, unavailable, paused, ready, sending, failed(ClipboardFailure)
}

/// Gates both directions of automatic text sharing to one foreground session.
/// The host supplies pasteboard change counts; only hashes are retained here.
/// Context changes establish a baseline, so text copied while sharing is paused
/// or disconnected is never forwarded later as an automatic catch-up operation.
public struct ClipboardSyncPolicy: Sendable {
    private var sessionID: UUID?
    private var isStreaming = false
    private var isForeground = false
    private var enabled = true
    private var observedChangeCount: Int?
    private var lastSentFingerprint: Data?
    private var lastSentAt: TimeInterval?
    private var sending = false
    private var failure: ClipboardFailure?

    public init() {}

    public var status: ClipboardSharingStatus {
        if !enabled { return .disabled }
        if sessionID == nil || !isStreaming { return .unavailable }
        if !isForeground { return .paused }
        if sending { return .sending }
        if let failure { return .failed(failure) }
        return .ready
    }

    public mutating func configure(sessionID: UUID?, isStreaming: Bool, isForeground: Bool,
                                   enabled: Bool, pasteboardChangeCount: Int) {
        let sessionChanged = self.sessionID != sessionID
        let contextChanged = sessionChanged || self.isStreaming != isStreaming
            || self.isForeground != isForeground || self.enabled != enabled
        if contextChanged || !enabled || !isStreaming || !isForeground {
            observedChangeCount = pasteboardChangeCount
        }
        if sessionChanged {
            lastSentFingerprint = nil
            lastSentAt = nil
        }
        if contextChanged {
            sending = false
            failure = nil
        }
        self.sessionID = sessionID
        self.isStreaming = isStreaming
        self.isForeground = isForeground
        self.enabled = enabled
    }

    /// Call once for each poll. A nil decision includes non-text and unchanged
    /// pasteboards; their change counts are still consumed to avoid later replay.
    public mutating func automaticText(_ text: String?, changeCount: Int, sessionID: UUID) throws -> String? {
        guard matches(sessionID), enabled, isForeground else { return nil }
        guard observedChangeCount != changeCount else { return nil }
        observedChangeCount = changeCount
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.count <= ClipboardTransferLimits.maximumTextBytes else {
            failure = .tooLarge
            throw ClipboardFailure.tooLarge
        }
        return text
    }

    /// A user-requested paste can work with automatic sharing switched off.
    public func validatePaste(_ text: String?, sessionID: UUID) throws -> String {
        guard matches(sessionID) else { throw ClipboardFailure.unavailable }
        guard isForeground else { throw ClipboardFailure.notFocused }
        guard let text, !text.isEmpty else { throw ClipboardFailure.empty }
        guard text.utf8.count <= ClipboardTransferLimits.maximumTextBytes else { throw ClipboardFailure.tooLarge }
        guard !sending else { throw ClipboardFailure.busy }
        return text
    }

    public mutating func sendStarted(text: String, sessionID: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard matches(sessionID), isForeground else { return }
        sending = true
        failure = nil
        lastSentFingerprint = Self.fingerprint(text)
        lastSentAt = now
    }

    public mutating func sendSucceeded(sessionID: UUID) {
        guard matches(sessionID) else { return }
        sending = false
        failure = nil
    }

    public mutating func sendFailed(_ failure: ClipboardFailure, sessionID: UUID) {
        guard matches(sessionID) else { return }
        sending = false
        self.failure = failure
    }

    public mutating func clearFailure() { failure = nil }

    /// Check before writing the Mac pasteboard, then call remoteWriteCompleted.
    /// Late callbacks from older streams and server echoes are ignored.
    public mutating func shouldApplyRemoteText(_ text: String, sessionID: UUID, currentLocalText: String? = nil,
                                              now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard matches(sessionID), enabled, isForeground,
              text.utf8.count <= ClipboardTransferLimits.maximumTextBytes else { return false }
        let fingerprint = Self.fingerprint(text)
        // Echo suppression is bounded: an intentional later copy of the same
        // value must still be able to replace a different Mac clipboard.
        if let lastSentAt, now - lastSentAt < 5, now >= lastSentAt, fingerprint == lastSentFingerprint { return false }
        if let currentLocalText, Self.fingerprint(currentLocalText) == fingerprint { return false }
        return true
    }

    public mutating func remoteWriteCompleted(changeCount: Int, sessionID: UUID) {
        guard matches(sessionID), enabled, isForeground else { return }
        observedChangeCount = changeCount
    }

    private func matches(_ candidate: UUID) -> Bool { sessionID == candidate && isStreaming }
    private static func fingerprint(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }
}

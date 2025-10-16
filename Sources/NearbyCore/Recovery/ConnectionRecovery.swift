import Foundation

public enum ConnectionRecoveryState: String, Equatable, Sendable {
    case idle, connecting, connected, recovering, waitingForNetwork, sleeping, paused, failed
}

/// Session intent survives transport failures, but never an explicit close.
/// The caller supplies monotonic seconds so sleep and wall-clock changes cannot
/// accidentally extend an automatic retry episode.
public struct ConnectionRecovery: Sendable {
    public static let maximumAttempts = 6
    public static let recoveryDuration: TimeInterval = 90
    public private(set) var state: ConnectionRecoveryState = .idle
    public private(set) var targetID: String?
    public private(set) var generation = UUID()
    public private(set) var attempts = 0
    public private(set) var deadline: TimeInterval?

    public init() {}

    @discardableResult public mutating func open(deviceID: String) -> UUID {
        generation = UUID(); targetID = deviceID; state = .connecting
        attempts = 0; deadline = nil
        return generation
    }

    public func accepts(_ token: UUID, deviceID: String) -> Bool {
        generation == token && targetID == deviceID
    }

    public mutating func connected() {
        guard targetID != nil, state == .connecting || state == .recovering else { return }
        state = .connected
    }

    /// A single decoded frame is not enough to reset a recovery episode: a
    /// flapping transport could otherwise retry forever. Clear its budget only
    /// after the caller observes a sustained usable stream.
    public mutating func connectionBecameStable() {
        guard state == .connected else { return }
        attempts = 0; deadline = nil
    }

    public mutating func interrupted(now: TimeInterval, automatically: Bool) {
        guard targetID != nil, ![.idle, .paused, .failed, .sleeping].contains(state) else { return }
        guard automatically else { pause(); return }
        if deadline != nil {
            if remaining(now: now) > 0 { state = .recovering }
            else { fail() }
        } else { recover(now: now) }
    }

    public mutating func recover(now: TimeInterval, automatically: Bool = true) {
        guard targetID != nil else { return }
        attempts = 0
        state = automatically ? .recovering : .paused
        deadline = automatically ? now + Self.recoveryDuration : nil
    }

    /// A cancellation retains the mirror for an explicit Try Again. Network
    /// notifications and wake events must not undo this choice.
    public mutating func pause() {
        guard targetID != nil else { return }
        state = .paused; deadline = nil
    }

    public mutating func sleep() {
        guard [.connecting, .connected, .recovering, .waitingForNetwork].contains(state) else { return }
        state = .sleeping; deadline = nil
    }

    public mutating func wake(now: TimeInterval, automatically: Bool) {
        guard state == .sleeping else { return }
        recover(now: now, automatically: automatically)
    }

    public mutating func waitForNetwork(now: TimeInterval) {
        guard state == .recovering || state == .waitingForNetwork else { return }
        if remaining(now: now) > 0 { state = .waitingForNetwork }
        else { fail() }
    }

    public mutating func networkAvailable(now: TimeInterval) {
        guard state == .waitingForNetwork else { return }
        if remaining(now: now) > 0 { state = .recovering }
        else { fail() }
    }

    public var nextDelay: TimeInterval {
        [0, 2, 4, 8, 12, 16][min(attempts, Self.maximumAttempts - 1)]
    }

    public func remaining(now: TimeInterval) -> TimeInterval {
        max(0, (deadline ?? now) - now)
    }

    /// Counts actual discovery/connection probes, including unsuccessful ones.
    /// Waiting for a missing network consumes elapsed time, not probe attempts.
    public mutating func beginAttempt(now: TimeInterval) -> Bool {
        guard state == .recovering else { return false }
        guard attempts < Self.maximumAttempts, remaining(now: now) > 0 else {
            fail(); return false
        }
        attempts += 1
        return true
    }

    public mutating func fail() {
        guard targetID != nil else { return }
        state = .failed; deadline = nil
    }

    public mutating func close() {
        generation = UUID(); targetID = nil; state = .idle
        attempts = 0; deadline = nil
    }
}

/// Discovery names are associated with hardware identities, never merely with a
/// previously used IP. ADB TLS still checks authorization when opening a trusted
/// endpoint, and the model verifies the returned hardware ID before streaming.
public enum ConnectionEndpointMatcher {
    public static func isTrusted(_ service: PairingService, for device: DeviceRecord) -> Bool {
        if let verified = device.discoveryServiceName, service.name == verified { return true }
        if serviceMatchesTransport(service, serial: device.serial), !device.serial.contains(":") { return true }
        guard !device.id.isEmpty, !device.id.hasPrefix("pending-"), !device.id.contains(":"),
              !device.id.contains("_adb-tls-connect") else { return false }
        let prefix = "adb-" + device.id + "-"
        return service.name.hasPrefix(prefix) && service.name.count > prefix.count
    }

    public static func serviceMatchesTransport(_ service: PairingService, serial: String) -> Bool {
        serial == service.address || serial == service.name ||
            serial.hasPrefix(service.name + "._adb-tls-connect._tcp")
    }
}

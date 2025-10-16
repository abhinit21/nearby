import Foundation

public enum ConnectionHealthResult: Equatable, Sendable {
    case verified
    case missingTransport
    case unavailableTransport
    case identityUnavailable
    case identityMismatch
    case devicesUnavailable
}

/// Identifies the actual stream transport, which can differ from the newest
/// endpoint in the device list. Each binding also has its own observation ID so
/// an old refresh cannot affect a later stream using the same generation/serial.
public struct ConnectionHealthTarget: Equatable, Sendable {
    public let deviceID: String
    public let generation: UUID
    public let serial: String
    private let observationID = UUID()

    public init(deviceID: String, generation: UUID, serial: String) {
        self.deviceID = deviceID; self.generation = generation; self.serial = serial
    }

    public func result(transport: ADBDevice?, hardwareIdentity: String?) -> ConnectionHealthResult {
        guard let transport, transport.serial == serial else { return .missingTransport }
        guard transport.status == "device" else { return .unavailableTransport }
        return result(hardwareIdentity: hardwareIdentity)
    }

    public func result(hardwareIdentity: String?) -> ConnectionHealthResult {
        guard let hardwareIdentity, !hardwareIdentity.isEmpty else { return .identityUnavailable }
        return hardwareIdentity == deviceID ? .verified : .identityMismatch
    }
}

public enum ConnectionHealthProbe {
    /// A direct round trip to the actual streaming transport is bounded even
    /// when unrelated device discovery is slow. Static video needs no packets.
    public static func check(_ target: ConnectionHealthTarget, adb: ADBClient) async throws -> ConnectionHealthResult {
        do {
            let identity = try await adb.checked(["-s", target.serial, "shell", "getprop", "ro.serialno"], timeout: 3)
            try Task.checkCancellation()
            return target.result(hardwareIdentity: identity)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            // Includes missing/offline/unauthorized transports and command
            // timeouts. None may be replaced with an earlier cached identity.
            return .identityUnavailable
        }
    }
}

/// Uses completed ADB round trips rather than video activity: a static phone
/// screen is healthy, while a loopback socket surviving a Wi-Fi blackhole is not
/// sufficient evidence that the intended Pixel remains reachable.
public struct ConnectionLiveness: Sendable {
    public private(set) var target: ConnectionHealthTarget?
    public private(set) var consecutiveFailures = 0
    public init() {}

    public mutating func monitor(deviceID: String, generation: UUID, serial: String) {
        target = ConnectionHealthTarget(deviceID: deviceID, generation: generation, serial: serial)
        consecutiveFailures = 0
    }

    /// Returns true exactly once after two consecutive completed failures for
    /// the same active binding. Cancellation/staleness must not be recorded as
    /// a health result by the caller.
    public mutating func record(_ result: ConnectionHealthResult, for observed: ConnectionHealthTarget) -> Bool {
        guard target == observed else { return false }
        if result == .verified { consecutiveFailures = 0; return false }
        consecutiveFailures += 1
        guard consecutiveFailures >= 2 else { return false }
        stop()
        return true
    }

    public mutating func stop() { target = nil; consecutiveFailures = 0 }
}

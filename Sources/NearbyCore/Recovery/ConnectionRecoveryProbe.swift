import Foundation

public struct RecoveredConnection: Equatable, Sendable {
    public let serial: String
    public let hardwareID: String
    public let discoveryServiceName: String?
}

/// The recovery adapter has no saved-address fallback. It opens only freshly
/// supplied, known Bonjour endpoints and verifies hardware after ADB TLS connects.
/// The owner validates its intent/deadline before and after every awaited command.
@MainActor
public enum ConnectionRecoveryProbe {
    public static func find(device: DeviceRecord, services: [PairingService], adb: ADBClient,
                            remaining: () throws -> TimeInterval) async throws -> RecoveredConnection? {
        func timeout(_ limit: TimeInterval) throws -> TimeInterval {
            try Task.checkCancellation()
            let seconds = try remaining()
            guard seconds > 0 else { throw ADBError.timedOut }
            return min(limit, seconds)
        }
        for service in services.filter({ ConnectionEndpointMatcher.isTrusted($0, for: device) }).prefix(3) {
            _ = try? await adb.checked(["connect", service.address], timeout: try timeout(4))
            _ = try timeout(4)
        }
        let output = try await adb.checked(["devices", "-l"], timeout: try timeout(4))
        _ = try timeout(4)
        for transport in ADBDevice.parse(output) where transport.status == "device" {
            let limit = try timeout(3)
            let identity = try? await adb.checked(["-s", transport.serial, "shell", "getprop", "ro.serialno"], timeout: limit)
            _ = try timeout(3)
            guard identity == device.id else { continue }
            return RecoveredConnection(serial: transport.serial, hardwareID: device.id,
                discoveryServiceName: services.first { ConnectionEndpointMatcher.serviceMatchesTransport($0, serial: transport.serial) }?.name)
        }
        return nil
    }
}

import Foundation
import Testing
@testable import NearbyCore

@MainActor
@Test func recoveryAdapterUsesFreshEndpointAndVerifiesTheHardwareBeforeReturning() async throws {
    let current = "192.168.2.44:40002"
    let fixture = try RecoveryADBFixture(devices: "\(current) device model:Pixel_9\n", identities: [current: "PIXEL123"])
    defer { fixture.remove() }
    let saved = DeviceRecord(id: "PIXEL123", serial: "192.168.1.10:30001", name: "Pixel")
    let fresh = PairingService(id: "fresh", name: "adb-PIXEL123-nonce", host: "192.168.2.44", port: 40002)
    let recovered = try await ConnectionRecoveryProbe.find(device: saved, services: [fresh], adb: fixture.client) { 90 }
    #expect(recovered?.serial == current)
    #expect(recovered?.hardwareID == "PIXEL123")
    #expect(recovered?.discoveryServiceName == fresh.name)
    let calls = try fixture.calls()
    #expect(calls.contains("connect \(current)"))
    #expect(calls.contains("-s \(current) shell getprop ro.serialno"))
    #expect(!calls.contains(saved.serial))
}

@MainActor
@Test func recoveryAdapterNeverProbesSavedIPsOrConnectsUnrelatedBonjourDevices() async throws {
    let stale = "192.168.1.10:30001"
    let fixture = try RecoveryADBFixture(devices: "\(stale) device model:Other_Phone\n", identities: [stale: "OTHER"])
    defer { fixture.remove() }
    let saved = DeviceRecord(id: "PIXEL123", serial: stale, name: "Pixel")
    let unrelated = PairingService(id: "other", name: "adb-OTHER-nonce", host: "192.168.1.10", port: 30001)
    let recovered = try await ConnectionRecoveryProbe.find(device: saved, services: [unrelated], adb: fixture.client) { 90 }
    #expect(recovered == nil)
    // Existing authorized transports may be inspected; they are never accepted
    // under the stale cached identity, and no old-IP connect is issued.
    let calls = try fixture.calls()
    #expect(!calls.contains("connect "))
    #expect(calls.contains("getprop ro.serialno"))
}

@MainActor
@Test func recoveryAdapterRejectsLateADBResultsAfterIntentChanges() async throws {
    let current = "192.168.2.44:40002"
    let fixture = try RecoveryADBFixture(devices: "\(current) device model:Pixel_9\n", identities: [current: "PIXEL123"], waitsForRelease: true)
    defer { fixture.remove() }
    let device = DeviceRecord(id: "PIXEL123", serial: "old:30001", name: "Pixel")
    let service = PairingService(id: "fresh", name: "adb-PIXEL123-nonce", host: "192.168.2.44", port: 40002)
    var currentIntent = true
    let task = Task { @MainActor in
        try await ConnectionRecoveryProbe.find(device: device, services: [service], adb: fixture.client) {
            guard currentIntent else { throw CancellationError() }
            return 90
        }
    }
    defer { task.cancel() }
    try await fixture.waitUntilConnectStarted()
    currentIntent = false
    try fixture.releaseConnect()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!(try fixture.calls()).contains("devices -l"))
}

@MainActor
@Test func recoveryAdapterCancellationTerminatesAnInFlightCommand() async throws {
    let fixture = try RecoveryADBFixture(devices: "", identities: [:], connectDelay: 10)
    defer { fixture.remove() }
    let device = DeviceRecord(id: "PIXEL123", serial: "old:30001", name: "Pixel")
    let service = PairingService(id: "fresh", name: "adb-PIXEL123-nonce", host: "192.168.2.44", port: 40002)
    let task = Task { @MainActor in
        try await ConnectionRecoveryProbe.find(device: device, services: [service], adb: fixture.client) { 90 }
    }
    defer { task.cancel() }
    try await fixture.waitUntilConnectStarted()
    task.cancel()
    let start = Date()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(start) < 2)
    #expect(!(try fixture.calls()).contains("devices -l"))
}

private struct RecoveryADBFixture {
    let root: URL
    let client: ADBClient
    private let log: URL
    private let release: URL

    init(devices: String, identities: [String: String], connectDelay: Double = 0, waitsForRelease: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nearby-recovery-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        log = root.appendingPathComponent("calls")
        release = root.appendingPathComponent("release")
        let executable = root.appendingPathComponent("adb-fixture")
        let cases = identities.map { Self.quote($0.key) + ") printf '%s\\n' " + Self.quote($0.value) + ";;" }.joined(separator: "\n")
        let sleep = (connectDelay > 5 ? "exec /bin/sleep " : "/bin/sleep ") + String(connectDelay)
        let barrier = waitsForRelease ? "while [ ! -f " + Self.quote(release.path) + " ]; do /bin/sleep 0.01; done; " : ""
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(Self.quote(log.path))
        case "$1" in
          connect) \(barrier)\(sleep); printf 'connected to %s\\n' "$2";;
          devices) printf '%s\\n' \(Self.quote(devices));;
          -s) case "$2" in
        \(cases)
          esac;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        client = ADBClient(executableURL: executable)
    }
    func calls() throws -> String { try String(contentsOf: log, encoding: .utf8) }
    func waitUntilConnectStarted() async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? calls().contains("connect ")) == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ADBError.command("The recovery test fixture did not start its connection command.")
    }
    func releaseConnect() throws { try Data().write(to: release) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

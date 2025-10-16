import Foundation
import XCTest
@testable import NearbyCore

@MainActor
final class ConnectionHealthProbeTests: XCTestCase {
    private let target = ConnectionHealthTarget(deviceID: "NEARBY-PIXEL-SAMPLE", generation: UUID(), serial: "192.0.2.4:40001")

    func testProbeChecksActualStreamingSerialAndRejectsWrongHardware() async throws {
        let fixture = try HealthADBFixture(response: "OTHER-PHONE")
        defer { fixture.remove() }
        let result = try await ConnectionHealthProbe.check(target, adb: fixture.client)
        XCTAssertEqual(result, .identityMismatch)
        XCTAssertEqual(try fixture.calls(), "-s \(target.serial) shell getprop ro.serialno\n")
    }

    func testMissingUnauthorizedAndOfflineTransportFailuresCannotUseCachedIdentity() async throws {
        for failure in ["device not found", "device unauthorized", "device offline"] {
            let fixture = try HealthADBFixture(response: failure, status: 1)
            defer { fixture.remove() }
            let result = try await ConnectionHealthProbe.check(target, adb: fixture.client)
            XCTAssertEqual(result, .identityUnavailable)
        }
    }

    func testPhoneBlackholeHasBoundedRoundTripEvenWhenLocalTransportStaysOpen() async throws {
        let fixture = try HealthADBFixture(blackhole: true)
        defer { fixture.remove() }
        let start = Date()
        let result = try await ConnectionHealthProbe.check(target, adb: fixture.client)
        XCTAssertEqual(result, .identityUnavailable)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCancellationIsNotReportedAsACompletedHealthFailure() async throws {
        let fixture = try HealthADBFixture(blackhole: true)
        defer { fixture.remove() }
        let target = self.target
        let task = Task { try await ConnectionHealthProbe.check(target, adb: fixture.client) }
        defer { task.cancel() }
        try await fixture.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled heartbeat must not return a failure or success sample")
        } catch is CancellationError { }
    }

    func testLateSuccessCannotResetAReplacementStreamsFailure() async throws {
        let fixture = try HealthADBFixture(response: target.deviceID, waitsForRelease: true)
        defer { fixture.remove() }
        var health = ConnectionLiveness()
        health.monitor(deviceID: target.deviceID, generation: target.generation, serial: target.serial)
        let old = health.target!
        let task = Task { try await ConnectionHealthProbe.check(old, adb: fixture.client) }
        defer { task.cancel() }
        try await fixture.waitUntilStarted()
        // A reconnect may retain both the engine object and streamGeneration.
        health.monitor(deviceID: old.deviceID, generation: old.generation, serial: old.serial)
        let replacement = health.target!
        XCTAssertFalse(health.record(.identityUnavailable, for: replacement))
        try fixture.release()
        let late = try await task.value
        XCTAssertEqual(late, .verified)
        XCTAssertFalse(health.record(late, for: old))
        XCTAssertEqual(health.consecutiveFailures, 1)
        XCTAssertTrue(health.record(.identityUnavailable, for: replacement))
    }

    func testCloseDiscardsAnAlreadyRunningLateFailure() async throws {
        let fixture = try HealthADBFixture(response: "OTHER-PHONE", waitsForRelease: true)
        defer { fixture.remove() }
        var health = ConnectionLiveness()
        health.monitor(deviceID: target.deviceID, generation: target.generation, serial: target.serial)
        let old = health.target!
        let task = Task { try await ConnectionHealthProbe.check(old, adb: fixture.client) }
        defer { task.cancel() }
        try await fixture.waitUntilStarted()
        health.stop()
        try fixture.release()
        let late = try await task.value
        XCTAssertEqual(late, .identityMismatch)
        XCTAssertFalse(health.record(late, for: old))
        XCTAssertNil(health.target)
    }
}

private struct HealthADBFixture: Sendable {
    let root: URL
    let client: ADBClient
    private let log: URL
    private let gate: URL
    init(response: String = "", status: Int = 0, blackhole: Bool = false, waitsForRelease: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nearby-health-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        log = root.appendingPathComponent("calls")
        gate = root.appendingPathComponent("release")
        let executable = root.appendingPathComponent("adb-fixture")
        let barrier = waitsForRelease ? "while [ ! -f " + Self.quote(gate.path) + " ]; do /bin/sleep 0.01; done" : ":"
        let operation = blackhole ? "exec /bin/sleep 10" : "printf '%s\\n' " + Self.quote(response) + "; exit " + String(status)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" > \(Self.quote(log.path))
        \(barrier)
        \(operation)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        client = ADBClient(executableURL: executable)
    }
    func calls() throws -> String { try String(contentsOf: log, encoding: .utf8) }
    func release() throws { try Data().write(to: gate) }
    func waitUntilStarted() async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if (try? calls().contains("getprop ro.serialno")) == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ADBError.command("The health test fixture did not start.")
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

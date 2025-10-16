import Foundation
import XCTest
@testable import NearbyCore

final class ConnectionLivenessTests: XCTestCase {
    private let deviceID = "NEARBY-PIXEL-SAMPLE"
    private let serial = "192.0.2.4:40001"

    private func monitored() -> (ConnectionLiveness, ConnectionHealthTarget) {
        var health = ConnectionLiveness()
        health.monitor(deviceID: deviceID, generation: UUID(), serial: serial)
        return (health, health.target!)
    }

    func testStaticScreenRemainsHealthyWithoutAnyVideoActivity() {
        var (health, target) = monitored()
        let transport = ADBDevice.parse("\(serial) device model:Pixel_9")[0]
        // No frame activity or clipboard signal is supplied to this policy.
        for _ in 0..<120 {
            XCTAssertFalse(health.record(target.result(transport: transport, hardwareIdentity: deviceID), for: target))
        }
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertEqual(health.target, target)
    }

    func testSingleTransientFailureDoesNotRecoverAndVerifiedRoundTripResetsIt() {
        var (health, target) = monitored()
        XCTAssertFalse(health.record(.identityUnavailable, for: target))
        XCTAssertEqual(health.consecutiveFailures, 1)
        XCTAssertFalse(health.record(.verified, for: target))
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertFalse(health.record(.identityUnavailable, for: target))
        XCTAssertTrue(health.record(.identityUnavailable, for: target))
        XCTAssertFalse(health.record(.identityUnavailable, for: target), "A failed binding may trigger recovery only once")
    }

    func testBlackholeIdentityTimeoutDoesNotAcceptAnOldCachedIdentity() {
        var (health, target) = monitored()
        let staleADBTransport = ADBDevice.parse("\(serial) device model:Pixel_9")[0]
        let result = target.result(transport: staleADBTransport, hardwareIdentity: nil)
        XCTAssertEqual(result, .identityUnavailable)
        XCTAssertFalse(health.record(result, for: target))
        XCTAssertTrue(health.record(result, for: target))
        XCTAssertNil(health.target)
    }

    func testMissingTransportAndOuterDevicesTimeoutBothCountAsCompletedFailures() {
        var (health, target) = monitored()
        XCTAssertEqual(target.result(transport: nil, hardwareIdentity: nil), .missingTransport)
        XCTAssertFalse(health.record(.missingTransport, for: target))
        XCTAssertTrue(health.record(.devicesUnavailable, for: target))
    }

    func testUnauthorizedOfflineAndWrongHardwareCannotCountAsSuccess() {
        let (_, target) = monitored()
        for state in ["unauthorized", "offline"] {
            let transport = ADBDevice.parse("\(serial) \(state)")[0]
            XCTAssertEqual(target.result(transport: transport, hardwareIdentity: deviceID), .unavailableTransport)
        }
        let transport = ADBDevice.parse("\(serial) device")[0]
        XCTAssertEqual(target.result(transport: transport, hardwareIdentity: "OTHER-PHONE"), .identityMismatch)
        XCTAssertEqual(target.result(transport: transport, hardwareIdentity: ""), .identityUnavailable)
    }

    func testResponsiveAlternateEndpointCannotMaskTheActualBlackholedStream() {
        let (_, target) = monitored()
        let alternate = ADBDevice.parse("192.0.2.5:40002 device model:Pixel_9")[0]
        XCTAssertEqual(target.result(transport: alternate, hardwareIdentity: deviceID), .missingTransport)
    }

    func testReplacedGenerationRejectsOldFailuresAndOldSuccesses() {
        var (health, old) = monitored()
        health.monitor(deviceID: deviceID, generation: UUID(), serial: serial)
        let replacement = health.target!
        XCTAssertFalse(health.record(.identityUnavailable, for: replacement))
        XCTAssertFalse(health.record(.verified, for: old), "An old success must not clear a newer failure")
        XCTAssertEqual(health.consecutiveFailures, 1)
        XCTAssertFalse(health.record(.identityUnavailable, for: old))
        XCTAssertEqual(health.consecutiveFailures, 1)
        XCTAssertTrue(health.record(.identityUnavailable, for: replacement))
    }

    func testNewStreamAttemptRejectsOldSamplesEvenWithSameGenerationAndSerial() {
        var (health, old) = monitored()
        health.monitor(deviceID: old.deviceID, generation: old.generation, serial: old.serial)
        let reconnected = health.target!
        XCTAssertNotEqual(old, reconnected)
        XCTAssertFalse(health.record(.identityUnavailable, for: reconnected))
        XCTAssertFalse(health.record(.verified, for: old))
        XCTAssertFalse(health.record(.identityUnavailable, for: old))
        XCTAssertTrue(health.record(.identityUnavailable, for: reconnected))
    }

    func testClosePauseSleepAndRecoveryDiscardPendingObservations() {
        for _ in ["closed", "paused", "sleeping", "recovering"] {
            var (health, target) = monitored()
            XCTAssertFalse(health.record(.identityUnavailable, for: target))
            health.stop()
            XCTAssertFalse(health.record(.identityUnavailable, for: target))
            XCTAssertFalse(health.record(.verified, for: target))
            XCTAssertNil(health.target)
        }
    }

    func testHealthFailureUsesExistingRecoveryPreferenceAndBudget() {
        for automatically in [false, true] {
            var recovery = ConnectionRecovery()
            let generation = recovery.open(deviceID: deviceID)
            recovery.connected()
            var health = ConnectionLiveness()
            health.monitor(deviceID: deviceID, generation: generation, serial: serial)
            let target = health.target!
            if health.record(.identityUnavailable, for: target) { XCTFail("One failed round trip must be tolerated") }
            if health.record(.identityUnavailable, for: target) { recovery.interrupted(now: 10, automatically: automatically) }
            XCTAssertEqual(recovery.state, automatically ? .recovering : .paused)
            XCTAssertEqual(recovery.deadline, automatically ? 100 : nil)
            // Late completed checks cannot launch another recovery episode.
            XCTAssertFalse(health.record(.identityUnavailable, for: target))
            XCTAssertEqual(recovery.attempts, 0)
        }
    }
}

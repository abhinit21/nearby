import Foundation
import Testing
@testable import NearbyCore

@Test func recoveryKeepsIntentUntilExplicitCloseAndRejectsOldCallbacks() {
    var recovery = ConnectionRecovery()
    let token = recovery.open(deviceID: "PIXEL123")
    recovery.connected()
    recovery.recover(now: 10)
    #expect(recovery.accepts(token, deviceID: "PIXEL123"))
    #expect(recovery.state == .recovering)
    recovery.close()
    recovery.wake(now: 20, automatically: true)
    recovery.networkAvailable(now: 20)
    #expect(recovery.state == .idle)
    #expect(recovery.targetID == nil)
    #expect(!recovery.accepts(token, deviceID: "PIXEL123"))
    recovery.open(deviceID: "OTHER")
    #expect(!recovery.accepts(token, deviceID: "PIXEL123"))
}

@Test func recoveryIsBoundedByBothAttemptCountAndElapsedTime() {
    var attempts = ConnectionRecovery()
    attempts.open(deviceID: "PIXEL123"); attempts.recover(now: 100)
    for number in 1...6 {
        let began25 = attempts.beginAttempt(now: 100 + Double(number))
        #expect(began25)
        #expect(attempts.attempts == number)
    }
    let began28 = attempts.beginAttempt(now: 110)
    #expect(!began28)
    #expect(attempts.state == .failed)
    var elapsed = ConnectionRecovery()
    elapsed.open(deviceID: "PIXEL123"); elapsed.recover(now: 100)
    let began32 = elapsed.beginAttempt(now: 189.9)
    #expect(began32)
    let began33 = elapsed.beginAttempt(now: 190)
    #expect(!began33)
    #expect(elapsed.state == .failed)
}

@Test func cancellationCannotBeUndoneBySleepWakeOrNetworkChanges() {
    var recovery = ConnectionRecovery()
    recovery.open(deviceID: "PIXEL123"); recovery.connected(); recovery.recover(now: 100)
    recovery.pause(); recovery.sleep(); recovery.wake(now: 200, automatically: true)
    recovery.networkAvailable(now: 200)
    recovery.connected() // A late first-frame callback cannot resume cancellation.
    #expect(recovery.state == .paused)
    let began44 = recovery.beginAttempt(now: 201)
    #expect(!began44)
    // Only a deliberate manual retry starts another bounded episode.
    recovery.recover(now: 300)
    let began47 = recovery.beginAttempt(now: 300)
    #expect(began47)
    #expect(recovery.deadline == 390)
}

@Test func sleepPausesBudgetAndWakeHonorsResumePreference() {
    var recovery = ConnectionRecovery()
    recovery.open(deviceID: "PIXEL123"); recovery.connected(); recovery.sleep()
    #expect(recovery.state == .sleeping)
    recovery.wake(now: 10_000, automatically: true)
    #expect(recovery.state == .recovering)
    #expect(recovery.deadline == 10_090)
    recovery.connected(); recovery.sleep(); recovery.wake(now: 20_000, automatically: false)
    #expect(recovery.state == .paused)
}

@Test func unavailableNetworkConsumesTimeButNotAttemptsAndNeverRestartsFailedRecovery() {
    var recovery = ConnectionRecovery()
    recovery.open(deviceID: "PIXEL123"); recovery.recover(now: 10)
    recovery.waitForNetwork(now: 20)
    #expect(recovery.state == .waitingForNetwork)
    #expect(recovery.attempts == 0)
    let began68 = recovery.beginAttempt(now: 21)
    #expect(!began68)
    recovery.networkAvailable(now: 30)
    let began70 = recovery.beginAttempt(now: 30)
    #expect(began70)
    recovery.waitForNetwork(now: 100)
    #expect(recovery.state == .failed)
    recovery.networkAvailable(now: 101)
    #expect(recovery.state == .failed)
}

@Test func endpointTrustFollowsKnownHardwareAcrossChangedAddresses() {
    let device = DeviceRecord(id: "PIXEL123", serial: "192.168.1.10:30001", name: "Pixel")
    let changed = PairingService(id: "new", name: "adb-PIXEL123-newnonce", host: "192.168.2.44", port: 40002)
    #expect(ConnectionEndpointMatcher.isTrusted(changed, for: device))
    let sameIPDifferentPhone = PairingService(id: "other", name: "adb-OTHER-nonce", host: "192.168.1.10", port: 30001)
    #expect(!ConnectionEndpointMatcher.isTrusted(sameIPDifferentPhone, for: device))
    #expect(!ConnectionEndpointMatcher.isTrusted(PairingService(id: "prefix", name: "adb-PIXEL1234-nonce", host: "192.168.2.44", port: 40002), for: device))
}

@Test func flappingFirstFramesDoNotResetAutomaticAttemptOrTimeBudgets() {
    var recovery = ConnectionRecovery()
    recovery.open(deviceID: "PIXEL123"); recovery.connected()
    recovery.interrupted(now: 100, automatically: true)
    for attempt in 1...6 {
        let began = recovery.beginAttempt(now: 100 + Double(attempt))
        #expect(began)
        recovery.connected() // Mirrors the real first-frame callback.
        #expect(recovery.deadline == 190)
        #expect(recovery.attempts == attempt)
        recovery.interrupted(now: 101 + Double(attempt), automatically: true)
    }
    let seventh = recovery.beginAttempt(now: 110)
    #expect(!seventh)
    #expect(recovery.state == .failed)
    recovery.interrupted(now: 111, automatically: true)
    #expect(recovery.state == .failed)
    recovery.recover(now: 200) // An explicit manual retry may reset the budget.
    let manual = recovery.beginAttempt(now: 200)
    #expect(manual)
    recovery.connected(); recovery.connectionBecameStable()
    recovery.interrupted(now: 300, automatically: true)
    #expect(recovery.attempts == 0)
    #expect(recovery.deadline == 390)
}

@Test func verifiedDiscoveryNameAndMDNSTransportSupportLegacySavedDevices() throws {
    let service = PairingService(id: "service", name: "vendor-nonce", host: "192.168.1.10", port: 40002)
    let verified = DeviceRecord(id: "HARDWARE", serial: "old:30001", name: "Pixel", discoveryServiceName: service.name)
    #expect(ConnectionEndpointMatcher.isTrusted(service, for: verified))
    let mdns = DeviceRecord(id: "vendor-nonce._adb-tls-connect._tcp", serial: "vendor-nonce._adb-tls-connect._tcp", name: "Pixel")
    #expect(ConnectionEndpointMatcher.isTrusted(service, for: mdns))
    let oldJSON = Data(#"{"id":"HARDWARE","serial":"old:30001","name":"Pixel","state":"unavailable","isWireless":true}"#.utf8)
    let decoded = try JSONDecoder().decode(DeviceRecord.self, from: oldJSON)
    #expect(decoded.discoveryServiceName == nil)
}

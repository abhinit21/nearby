import Foundation
import Testing
@testable import NearbyCore

@Test func deviceListParsingHandlesBothTransportsAndAuthorization() {
    let parsed = ADBDevice.parse("""
    List of devices attached
    USB123 device usb:1-1 product:tokay model:Pixel_9 transport_id:1
    192.168.1.12:37123 device product:tokay model:Pixel_9 transport_id:2
    adb-OTHER._adb-tls-connect._tcp unauthorized transport_id:3
    offline123 offline transport_id:4
    """)
    #expect(parsed.count == 4)
    #expect(parsed[0].model == "Pixel 9")
    #expect(!parsed[0].isWireless)
    #expect(parsed[1].isWireless)
    #expect(parsed[2].isWireless)
    #expect(parsed[2].status == "unauthorized")
    #expect(parsed[3].status == "offline")
}

@Test func codeAcceptsPastedWhitespaceButRejectsWrongLengthAndUnicode() {
    #expect(PairingCode.normalized(" 482 716\n") == "482716")
    #expect(PairingCode.normalized("048271") == "048271")
    for input in ["4827", "4827160", "４８２７１６", "482x16", "482;16"] {
        #expect(PairingCode.normalized(input) == nil)
    }
}

@Test func freshQRAttemptsHaveUnpredictableIndependentSecretsAndServiceNames() throws {
    let a = try QRPairingAttempt(), b = try QRPairingAttempt()
    #expect(a.serviceName != b.serviceName)
    #expect(a.secret != b.secret)
    #expect(a.secret.utf8.count == 32)
    #expect(a.payload.hasPrefix("WIFI:T:ADB;S:studio-"))
    #expect(a.payload.hasSuffix(";;"))
    #expect(a.payload.contains(";P:"))
}

@Test func addressesValidatePortsAndDoNotAcceptOptionsOrShellSyntax() throws {
    for valid in ["192.168.1.1:37123", "pixel.local:40123", "[fe80::1%en0]:12345", " [::1]:65535 "] {
        #expect(try ConnectionAddress(valid).value == valid.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    for invalid in ["-s", "192.168.1.1", "192.168.1.1:0", "192.168.1.1:65536", "host:12 34", "host;rm:5555", "$(bad):5555", "::1:5555", "[::1]:abc", "host:5555\n--option"] {
        #expect(throws: (any Error).self) { try ConnectionAddress(invalid) }
    }
}

@Test func adbArgumentsAreLiteralAndNonzeroStatusIsPreserved() async throws {
    let echo = ADBClient(executableURL: URL(fileURLWithPath: "/bin/echo"))
    let result = try await echo.checked(["literal; $(do-not-run) `nor-this`"], timeout: 2)
    #expect(result == "literal; $(do-not-run) `nor-this`")
    let shell = ADBClient(executableURL: URL(fileURLWithPath: "/bin/sh"))
    let failed = try await shell.run(["-c", "echo specific-error >&2; exit 7"], timeout: 2)
    #expect(failed.status == 7)
    #expect(failed.stderr.contains("specific-error"))
}

@Test func commandsTimeOutAndCancellationTerminatesWait() async throws {
    let client = ADBClient(executableURL: URL(fileURLWithPath: "/bin/sleep"))
    let start = Date()
    await #expect(throws: (any Error).self) { try await client.run(["20"], timeout: 0.08) }
    #expect(Date().timeIntervalSince(start) < 2)
    let task = Task { try await client.run(["20"], timeout: 30) }
    try await Task.sleep(for: .milliseconds(80)); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func simultaneousStdoutAndStderrDoNotDeadlock() async throws {
    let client = ADBClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"))
    let result = try await client.run(["-c", "import sys; sys.stdout.write('x'*200000); sys.stderr.write('y'*200000)"], timeout: 5)
    #expect(result.status == 0)
    #expect(result.stdout.utf8.count == 200_000)
    #expect(result.stderr.utf8.count == 200_000)
}

@Test func pairingFailuresExplainNetworkProblemsAndRedactSecrets() {
    let secret = "482716abcdef0123456789abcdef012345"
    let blocked = PairingFailure(error: ADBError.command("connect denied: Operation not permitted; password=" + secret), secret: secret)
    #expect(blocked.message.contains("macOS blocked"))
    #expect(!blocked.detail.contains(secret))
    #expect(blocked.detail.contains("[redacted]"))
    let route = PairingFailure(error: ADBError.command("No route to host"), secret: secret)
    #expect(route.message.contains("couldn't reach"))
    let timedOut = PairingFailure(error: ADBError.timedOut, secret: secret)
    #expect(timedOut.message.contains("timed out"))
    let stopped = PairingFailure(error: ADBError.command("cannot connect to daemon at tcp:127.0.0.1:53905: Connection refused"), secret: secret)
    #expect(stopped.message.contains("connection service stopped"))
    #expect(!stopped.message.contains("same Wi-Fi"))
}

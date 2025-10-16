import XCTest
import Darwin
@testable import NearbyCore

@MainActor
final class ADBServerTests: XCTestCase {
    func testOwnedServerUsesPrivatePortAndStopsOnlyTrackedChild() async throws {
        let fixture = try FakeADBServer()
        defer { fixture.remove() }
        let server = OwnedADBServer(adbURL: fixture.executable)
        let client = try await server.start()
        let port = try XCTUnwrap(client.serverPort)
        XCTAssertNotEqual(port, 5037)
        XCTAssertEqual(server.serverPort, port)
        XCTAssertEqual(client.baseArguments, ["-H", "127.0.0.1", "-P", String(port)])
        let reused = try await server.start()
        XCTAssertTrue(reused === client, "Start must reuse its live owned child")
        let echoed = try await client.checked(["devices", "-l"], timeout: 2)
        XCTAssertEqual(echoed, "-H|127.0.0.1|-P|\(port)|devices|-l")
        await server.stopOwnServer()
        await server.stopOwnServer()
        let events = fixture.events
        let starts = events.filter { $0["kind"] as? String == "server" }
        XCTAssertEqual(starts.count, 1)
        let start = try XCTUnwrap(starts.first)
        XCTAssertEqual(start["args"] as? [String], ["-L", "tcp:\(port)", "--one-device", "nearby-wireless-only", "server", "nodaemon"])
        XCTAssertFalse((start["args"] as? [String])?.contains("-a") == true, "Without -a, tcp:<port> must stay loopback-only")
        XCTAssertTrue(start["trace"] is NSNull)
        XCTAssertEqual(start["rejectKill"] as? String, "1")
        XCTAssertEqual(start["autoConnect"] as? String, "0")
        XCTAssertEqual(start["home"] as? String, ProcessInfo.processInfo.environment["HOME"])
        XCTAssertEqual(events.filter { $0["kind"] as? String == "stopped" }.count, 1)
        XCTAssertFalse(events.contains { ($0["args"] as? [String])?.contains("kill-server") == true })
        XCTAssertNil(server.serverPort)
        let pid = try XCTUnwrap(start["pid"] as? Int32)
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "Awaited stop must reap the owned process")
        XCTAssertEqual(errno, ESRCH)
    }

    func testBindCollisionRetriesWithoutFallingBackToSharedPort() async throws {
        let fixture = try FakeADBServer(mode: "collision")
        defer { fixture.remove() }
        let server = OwnedADBServer(adbURL: fixture.executable)
        let client = try await server.start()
        await server.stopOwnServer()
        let starts = fixture.events.filter { $0["kind"] as? String == "server" }
        XCTAssertEqual(starts.count, 2)
        let sockets = starts.compactMap { ($0["args"] as? [String])?[1] }
        XCTAssertEqual(Set(sockets).count, 2)
        XCTAssertTrue(sockets.allSatisfy { $0.hasPrefix("tcp:") && $0.split(separator: ":").count == 2 && !$0.hasSuffix(":5037") })
        XCTAssertEqual(sockets.last, "tcp:\(try XCTUnwrap(client.serverPort))")
    }

    func testCanceledStartupWaitsForOwnedChildTermination() async throws {
        let fixture = try FakeADBServer(mode: "slow")
        defer { fixture.remove() }
        let server = OwnedADBServer(adbURL: fixture.executable)
        let startup = Task { try await server.start() }
        for _ in 0..<150 {
            if fixture.events.contains(where: { $0["kind"] as? String == "server" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(fixture.events.first?["pid"] as? Int32)
        startup.cancel()
        do { _ = try await startup.value; XCTFail("Canceled startup must not return a usable client") }
        catch { XCTAssertTrue(error is CancellationError) }
        await server.stopOwnServer()
        XCTAssertNil(server.serverPort)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(fixture.events.filter { $0["kind"] as? String == "stopped" }.count, 1)
    }

    func testUnreadyChildIsBoundedAndForceStopped() async throws {
        let fixture = try FakeADBServer(mode: "ignore")
        defer { fixture.remove() }
        let server = OwnedADBServer(adbURL: fixture.executable, startupTimeout: 0.8)
        let began = ProcessInfo.processInfo.systemUptime
        do { _ = try await server.start(); XCTFail("Unready server must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not become ready")) }
        await server.stopOwnServer()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 3)
        let pid = try XCTUnwrap(fixture.events.first?["pid"] as? Int32)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testUnexpectedExitInvalidatesClientBeforeCallbackAndCanRestart() async throws {
        let fixture = try FakeADBServer()
        defer { fixture.remove() }
        let server = OwnedADBServer(adbURL: fixture.executable)
        var diagnostics: [String] = []
        var wasInvalidatedBeforeCallback = false
        server.onUnexpectedExit = { [weak server] detail in
            wasInvalidatedBeforeCallback = server?.isRunning == false && server?.serverPort == nil
            diagnostics.append(detail)
        }
        let firstClient = try await server.start()
        XCTAssertTrue(server.isRunning)
        try fixture.triggerUnexpectedExit()
        for _ in 0..<200 {
            if !diagnostics.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let diagnostic = try XCTUnwrap(diagnostics.first)
        XCTAssertTrue(wasInvalidatedBeforeCallback)
        XCTAssertFalse(server.isRunning)
        XCTAssertNil(server.serverPort)
        XCTAssertEqual(server.lastExitDiagnostic, diagnostic)
        XCTAssertTrue(diagnostic.contains("status 23"))
        XCTAssertTrue(diagnostic.contains("mutex::lock"))
        XCTAssertFalse(diagnostic.contains("482716abcdef0123456789abcdef012345"))
        XCTAssertFalse(diagnostic.contains("192.168.1.6"))
        XCTAssertTrue(diagnostic.contains("[redacted]"))
        let restarted = try await server.start()
        XCTAssertFalse(firstClient === restarted)
        XCTAssertTrue(server.isRunning)
        XCTAssertEqual(fixture.events.filter { $0["kind"] as? String == "server" }.count, 2)
        await server.stopOwnServer()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(diagnostics.count, 1, "Intentional stops and stale exit delivery must not emit another health failure")
        XCTAssertFalse(server.isRunning)
    }
}

/// A Python TCP protocol specimen, never the real bundled ADB executable.
private struct FakeADBServer {
    let folder: URL
    let executable: URL
    private let log: URL
    init(mode: String = "ready") throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NearbyOwnedADB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        executable = folder.appendingPathComponent("fake-adb")
        log = folder.appendingPathComponent("events.jsonl")
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        let quotedLog = String(decoding: try encoder.encode(log.path), as: UTF8.self)
        let quotedMode = String(decoding: try encoder.encode(mode), as: UTF8.self)
        try """
        #!/usr/bin/python3
        import json, os, re, signal, socket, sys, time
        log = \(quotedLog)
        mode = \(quotedMode)
        args = sys.argv[1:]
        def record(kind):
            with open(log, 'a') as f:
                f.write(json.dumps({'kind':kind,'args':args,'pid':os.getpid(),
                    'trace':os.environ.get('ADB_TRACE'),'rejectKill':os.environ.get('ADB_REJECT_KILL_SERVER'),
                    'autoConnect':os.environ.get('ADB_MDNS_AUTO_CONNECT'),
                    'home':os.environ.get('HOME')}) + '\\n')
        if args[:1] != ['-L']:
            record('command')
            print('|'.join(args))
            sys.exit(0)
        record('server')
        # Supported ADB listener parsing rejects numeric-host forms such as
        # tcp:127.0.0.1:PORT. Keep the specimen strict about accepted syntax.
        if not re.fullmatch(r'tcp:[0-9]+', args[1]) or '-a' in args:
            print('listening on specified hostname currently unsupported', file=sys.stderr)
            sys.exit(11)
        def stopped(*unused):
            record('stopped')
            sys.exit(0)
        signal.signal(signal.SIGINT, signal.SIG_IGN if mode == 'ignore' else stopped)
        if mode == 'collision' and not os.path.exists(log + '.once'):
            open(log + '.once', 'w').close()
            print('cannot bind listener: Address already in use', file=sys.stderr)
            sys.exit(1)
        if mode in ['slow', 'ignore']:
            time.sleep(30)
            sys.exit(1)
        port = int(args[1].rsplit(':',1)[1])
        if port == 5037:
            sys.exit(9)
        listener = socket.socket()
        listener.bind(('127.0.0.1',port))
        listener.listen()
        listener.settimeout(0.05)
        while True:
            if os.path.exists(log + '.exit'):
                os.unlink(log + '.exit')
                print('mutex::lock failed; host:pair:482716abcdef0123456789abcdef012345:192.168.1.6:37123', file=sys.stderr, flush=True)
                print('secret=482716abcdef0123456789abcdef012345', file=sys.stderr, flush=True)
                sys.exit(23)
            try:
                conn, address = listener.accept()
            except socket.timeout:
                continue
            with conn:
                request = b''
                while len(request) < 16:
                    part = conn.recv(16 - len(request))
                    if not part: break
                    request += part
                if request == b'000chost:version':
                    conn.sendall(b'OKAY00040029')
        """.write(to: executable, atomically: true, encoding: .utf8)
        if mode == "ignore" {
            // Keep the intentionally short startup deadline independent of Python's
            // cold launch time. exec retains the PID and ignored SIGINT disposition.
            let shellLog = "'" + log.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            try """
            #!/bin/sh
            trap '' INT
            printf '{"kind":"server","pid":%d}\\n' "$$" >> \(shellLog)
            exec /bin/sleep 30
            """.write(to: executable, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    var events: [[String: Any]] {
        guard let data = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return data.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }
    func triggerUnexpectedExit() throws {
        try Data([1]).write(to: URL(fileURLWithPath: log.path + ".exit"))
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

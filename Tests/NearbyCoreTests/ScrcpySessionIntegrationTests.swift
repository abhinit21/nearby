import XCTest
import Darwin
@testable import NearbyCore

/// A local pinned-protocol peer, never an Android device. Exercises real TCP,
/// VideoToolbox, native frame delivery, control writes, and session teardown.
private final class SyntheticScrcpyPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [Int32] = []
    private var input = Data()
    private var controlDescriptor: Int32?
    private let acknowledgesClipboard: Bool
    let port: UInt16
    private let listener: Int32
    init(acknowledgesClipboard: Bool = true) throws {
        self.acknowledgesClipboard = acknowledgesClipboard
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, Darwin.listen(descriptor, 2) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async { [self] in run() }
    }
    var received: Data { lock.lock(); defer { lock.unlock() }; return input }
    func sendRemoteClipboard(_ text: String) {
        lock.lock(); let descriptor = controlDescriptor; lock.unlock()
        guard let descriptor else { return }
        var message = Data([0]); message.appendBE(UInt32(text.utf8.count)); message.append(contentsOf: text.utf8)
        write(message, to: descriptor)
    }
    func sendAcknowledgement(_ sequence: UInt64) {
        sendAcknowledgements([sequence])
    }
    func sendAcknowledgements(_ sequences: [UInt64]) {
        lock.lock(); let descriptor = controlDescriptor; lock.unlock()
        guard let descriptor else { return }
        var message = Data()
        for sequence in sequences { message.append(1); message.appendBE(sequence) }
        write(message, to: descriptor)
    }
    func stop() {
        lock.lock(); let descriptors = sockets; sockets = []; lock.unlock()
        Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener)
        for descriptor in descriptors { Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor) }
    }
    private func add(_ fd: Int32) { lock.lock(); sockets.append(fd); lock.unlock() }
    private func write(_ data: Data, to descriptor: Int32) {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard sent > 0 else { return }; offset += sent
        }
    }
    private func run() {
        let video = Darwin.accept(listener, nil, nil)
        guard video >= 0 else { return }; add(video)
        var yes: Int32 = 1
        setsockopt(video, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        write(Data([0]), to: video)
        let control = Darwin.accept(listener, nil, nil)
        guard control >= 0 else { return }; add(control)
        setsockopt(control, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        lock.lock(); controlDescriptor = control; lock.unlock()
        var packet = Data(repeating: 0, count: 64)
        packet.appendBE(UInt32(0x68323634)); packet.appendBE(UInt32(64)); packet.appendBE(UInt32(96))
        let h264 = Data(base64Encoded: "AAAAAWdCwAraENsBEAAAAwAQAAADACjxImoAAAABaM4PyAAAAWWIhDoRigACMXHAAEPKOAAIBcnJyddddddddddddddddddddeA=")!
        packet.appendBE(UInt64(1 << 62)); packet.appendBE(UInt32(h264.count)); packet.append(h264)
        write(packet, to: video)
        var bytes = [UInt8](repeating: 0, count: 4096)
        var pending = Data()
        while true {
            let count = Darwin.recv(control, &bytes, bytes.count, 0)
            guard count > 0 else { break }
            lock.lock(); input.append(contentsOf: bytes.prefix(count)); lock.unlock()
            pending.append(contentsOf: bytes.prefix(count))
            messages: while let type = pending.first {
                let size: Int
                switch type {
                case 0: size = 14
                case 1:
                    guard pending.count >= 5 else { break messages }
                    size = 5 + Int(pending.uint32BE(at: 1))
                case 2: size = 32
                case 3: size = 21
                case 9:
                    guard pending.count >= 14 else { break messages }
                    size = 14 + Int(pending.uint32BE(at: 10))
                case 10: size = 2
                default: return
                }
                guard pending.count >= size else { break }
                if type == 9, acknowledgesClipboard {
                    sendAcknowledgement(pending.uint64BE(at: 1))
                }
                pending = Data(pending.dropFirst(size))
            }
        }
    }
}

@MainActor final class ScrcpySessionIntegrationTests: XCTestCase {
    private func clipboardFixture(peer: SyntheticScrcpyPeer) async throws -> (ScrcpySession, URL) {
        let (session, folder) = try makeSession(peer: peer)
        try await session.start(serial: "synthetic-clipboard")
        return (session, folder)
    }

    private func makeSession(peer: SyntheticScrcpyPeer) throws -> (ScrcpySession, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NearbyClipboardPeer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("adb")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(folder.appendingPathComponent("calls").path)'
        if [ "$3" = "forward" ] && [ "$4" = "tcp:0" ]; then echo \(peer.port); fi
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let server = folder.appendingPathComponent("server"); try Data([0]).write(to: server)
        let session = ScrcpySession(adb: ADBClient(executableURL: executable), serverURL: server, serverVersion: "3.3.4")
        return (session, folder)
    }

    private final class ProcessingObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [Bool] = []
        let release = DispatchSemaphore(value: 0)
        func record(block: Bool = false) {
            lock.lock(); observations.append(Thread.isMainThread); lock.unlock()
            if block { release.wait() }
        }
        var values: [Bool] { lock.lock(); defer { lock.unlock() }; return observations }
    }

    func testQuitDeadlineReleasesBlockedWorkerJoinAfterOwnedADBCleanup() async throws {
        let peer = try SyntheticScrcpyPeer()
        defer { peer.stop() }
        let (session, folder) = try makeSession(peer: peer)
        defer { try? FileManager.default.removeItem(at: folder) }
        let observation = ProcessingObservation()
        defer { observation.release.signal() }
        session.videoProcessingObserver = { observation.record(block: true) }
        let startup = Task { try await session.start(serial: "blocked-quit-stream") }
        for _ in 0..<100 {
            if !observation.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !observation.values.isEmpty else { session.stop(); XCTFail("The worker never reached decoding"); return }
        session.stop()
        do { try await startup.value; XCTFail("The stopped startup must fail") } catch {}
        let callsURL = folder.appendingPathComponent("calls")
        var recorded = ""
        for _ in 0..<100 {
            recorded = (try? String(contentsOf: callsURL, encoding: .utf8)) ?? ""
            if recorded.contains("forward --remove tcp:\(peer.port)"), recorded.contains("shell rm -f") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(recorded.contains("forward --remove tcp:\(peer.port)"), "The owned forward must be removed while native decode is still blocked")
        XCTAssertTrue(recorded.contains("shell rm -f"), "Remote-file cleanup must run before waiting for native decode")
        let startedWaiting = scrcpyMonotonicTime()
        await session.stopAndWait(cleanupTimeout: .milliseconds(50))
        XCTAssertLessThan(scrcpyMonotonicTime() - startedWaiting, 1, "The quit deadline must cancel a blocked native join")
        XCTAssertFalse(session.isStreaming)
        XCTAssertNil(session.screenshot())
    }

    func testRestartRejectsOutputFromBlockedOldDecoderWithoutBlockingUIStop() async throws {
        let oldPeer = try SyntheticScrcpyPeer()
        let replacementPeer = try SyntheticScrcpyPeer()
        defer { oldPeer.stop(); replacementPeer.stop() }
        let (session, folder) = try makeSession(peer: oldPeer)
        defer { try? FileManager.default.removeItem(at: folder) }
        let observation = ProcessingObservation()
        session.videoProcessingObserver = { observation.record(block: true) }
        var firstFrames = 0
        session.onFirstFrame = { firstFrames += 1 }
        let oldStartup = Task { try await session.start(serial: "blocked-old-stream") }
        for _ in 0..<100 {
            if !observation.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !observation.values.isEmpty else {
            observation.release.signal(); session.stop(); XCTFail("The old worker never reached decoding"); return
        }
        XCTAssertEqual(observation.values, [false], "Blocking reads and decoder work must run off the main thread")
        let replacementADB = folder.appendingPathComponent("replacement-adb")
        try """
        #!/bin/sh
        if [ "$3" = "forward" ] && [ "$4" = "tcp:0" ]; then echo \(replacementPeer.port); fi
        exit 0
        """.write(to: replacementADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacementADB.path)
        session.videoProcessingObserver = nil
        // start calls stop synchronously. It must be able to replace a stream
        // while the old dedicated decoder queue is deliberately held here.
        do {
            try await session.start(serial: "replacement-stream", using: ADBClient(executableURL: replacementADB))
        } catch {
            observation.release.signal(); await session.stopAndWait(); throw error
        }
        observation.release.signal()
        do { try await oldStartup.value; XCTFail("The replaced startup must fail") } catch {}
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(session.isStreaming)
        XCTAssertEqual(firstFrames, 1, "The old worker must not deliver a first frame into the new generation")
        XCTAssertEqual(session.decodedFrameCount, 1)
        await session.stopAndWait()
    }

    func testUnicodeClipboardIsAcknowledgedAndRoundTripsWithoutKeyInjection() async throws {
        let peer = try SyntheticScrcpyPeer()
        defer { peer.stop() }
        let (session, folder) = try await clipboardFixture(peer: peer)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = "Nearby test — नमस्ते, こんにちは, مرحبا, 🪷👩🏽‍💻\nSecond line"
        try await session.sendClipboard(text, paste: true)
        let packet = peer.received
        XCTAssertEqual(packet.first, 9)
        XCTAssertNotEqual(packet.uint64BE(at: 1), 0)
        XCTAssertEqual(packet[9], 1)
        XCTAssertEqual(String(data: packet.dropFirst(14), encoding: .utf8), text)
        var received: String?
        session.onClipboard = { received = $0 }
        peer.sendRemoteClipboard(text)
        for _ in 0..<100 {
            if received != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(received, text)
        let beforeOversize = peer.received
        do {
            try await session.sendClipboard(String(repeating: "a", count: ClipboardTransferLimits.maximumTextBytes + 1), paste: true)
            XCTFail("Oversized text must be rejected")
        } catch { XCTAssertEqual(error as? ClipboardFailure, .tooLarge) }
        XCTAssertEqual(peer.received, beforeOversize, "No partial clipboard data should be sent")
        await session.stopAndWait()
    }

    func testClipboardTimeoutCancellationAndLateAcknowledgementsRemainBounded() async throws {
        let peer = try SyntheticScrcpyPeer(acknowledgesClipboard: false)
        defer { peer.stop() }
        let (session, folder) = try await clipboardFixture(peer: peer)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try await session.sendClipboard("harmless timeout test", paste: false, timeout: 0.08)
            XCTFail("An absent acknowledgement must time out")
        } catch { XCTAssertEqual(error as? ClipboardFailure, .timedOut) }
        XCTAssertTrue(session.isStreaming, "A clipboard timeout must leave the video usable")
        peer.sendAcknowledgement(1) // Late acknowledgement cannot satisfy operation 2.
        let pending = Task { try await session.sendClipboard("harmless cancellation test", paste: false) }
        try await Task.sleep(for: .milliseconds(30))
        pending.cancel()
        do { try await pending.value; XCTFail("Cancelled operation must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(session.isStreaming)
        let interrupted = Task { try await session.sendClipboard("harmless disconnect test", paste: false) }
        try await Task.sleep(for: .milliseconds(30))
        await session.stopAndWait()
        do { try await interrupted.value; XCTFail("Ended session must invalidate its pending operation") }
        catch { XCTAssertEqual(error as? ClipboardFailure, .connectionLost) }
    }

    func testOrderedControlBurstPreservesEveryAcknowledgementAndCanStopInsideCallback() async throws {
        let peer = try SyntheticScrcpyPeer(acknowledgesClipboard: false)
        defer { peer.stop() }
        let (session, folder) = try await clipboardFixture(peer: peer)
        defer { try? FileManager.default.removeItem(at: folder) }
        var clipboardMessages: [String] = []
        session.onClipboard = { [weak session] text in
            clipboardMessages.append(text)
            if text == "last" { session?.stop() }
        }
        let transfers = (0..<8).map { _ in
            Task { try await session.sendClipboard("burst", paste: false) }
        }
        for _ in 0..<100 {
            if peer.received.count >= 8 * (14 + "burst".utf8.count) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(peer.received.count, 8 * (14 + "burst".utf8.count))
        peer.sendRemoteClipboard("first")
        peer.sendAcknowledgements([8, 1, 7, 2, 6, 3, 5, 4])
        peer.sendRemoteClipboard("last")
        // ACKs must all complete before the following ordered clipboard callback
        // stops the stream. A synchronous UI stop must not deadlock its reader.
        for transfer in transfers { try await transfer.value }
        for _ in 0..<100 {
            if clipboardMessages.last == "last" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(clipboardMessages, ["first", "last"])
        XCTAssertFalse(session.isStreaming)
        await session.stopAndWait()
    }

    func testReplacementStreamInvalidatesOldClipboardWorkAndKeepsCallback() async throws {
        let oldPeer = try SyntheticScrcpyPeer(acknowledgesClipboard: false)
        let replacementPeer = try SyntheticScrcpyPeer()
        defer { oldPeer.stop(); replacementPeer.stop() }
        let (session, folder) = try await clipboardFixture(peer: oldPeer)
        defer { try? FileManager.default.removeItem(at: folder) }
        var received: String?
        session.onClipboard = { received = $0 }
        let oldOperation = Task { try await session.sendClipboard("harmless old-session test", paste: false) }
        try await Task.sleep(for: .milliseconds(30))
        let replacementADB = folder.appendingPathComponent("replacement-adb")
        try """
        #!/bin/sh
        if [ "$1" = "-H" ]; then shift 4; fi
        if [ "$3" = "forward" ] && [ "$4" = "tcp:0" ]; then echo \(replacementPeer.port); fi
        exit 0
        """.write(to: replacementADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacementADB.path)
        try await session.start(serial: "replacement-synthetic", using: ADBClient(executableURL: replacementADB, serverPort: 49173))
        do { try await oldOperation.value; XCTFail("Old clipboard work must not survive replacement") }
        catch { XCTAssertEqual(error as? ClipboardFailure, .connectionLost) }
        XCTAssertTrue(session.isStreaming)
        try await session.sendClipboard("harmless new-session 🪷", paste: true)
        replacementPeer.sendRemoteClipboard("replacement clipboard 🪷")
        for _ in 0..<100 {
            if received != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(received, "replacement clipboard 🪷", "Callbacks must survive stream restart")
        await session.stopAndWait()
    }

    func testNativeStreamControlsScreenshotAndDisplayRestoreAgainstSyntheticPeer() async throws {
        let peer = try SyntheticScrcpyPeer()
        defer { peer.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NearbyNativePeer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("adb")
        let calls = folder.appendingPathComponent("calls")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(calls.path)'
        if [ "$1" = "-H" ]; then shift 4; fi
        if [ "$3" = "forward" ] && [ "$4" = "tcp:0" ]; then echo \(peer.port); fi
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let server = folder.appendingPathComponent("server"); try Data([0]).write(to: server)
        let session = ScrcpySession(adb: ADBClient(executableURL: executable, serverPort: 49173), serverURL: server, serverVersion: "3.3.4")
        var firstFrames = 0
        var samples: [StreamPerformanceSample] = []
        let observation = ProcessingObservation()
        session.videoProcessingObserver = { observation.record() }
        session.onFirstFrame = { firstFrames += 1 }
        session.onPerformanceSample = { samples.append($0) }
        try await session.start(serial: "synthetic-only", options: StreamOptions())
        XCTAssertTrue(session.isStreaming)
        XCTAssertEqual(firstFrames, 1)
        XCTAssertEqual(session.videoSize, CGSize(width: 64, height: 96))
        XCTAssertEqual(session.decodedFrameCount, 1)
        XCTAssertEqual(observation.values, [false])
        let image = try XCTUnwrap(session.screenshot())
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 96)
        session.keycode(3)
        session.touch(x: 1, y: 0, phase: .down)
        XCTAssertTrue(session.isTouchActive)
        session.touch(x: 0.8, y: 0.2, phase: .move)
        XCTAssertTrue(session.isTouchActive)
        session.touch(x: 1, y: 0, phase: .up)
        XCTAssertFalse(session.isTouchActive)
        session.setScreenPower(false)
        for _ in 0..<50 {
            if peer.received.suffix(2) == Data([10, 0]) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(peer.received.starts(with: ControlProtocol.keycode(3, down: true)))
        for _ in 0..<125 {
            if !samples.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sample = try XCTUnwrap(samples.first, "Even a static stream must emit periodic, generation-owned performance samples")
        XCTAssertGreaterThanOrEqual(sample.interval, 2)
        XCTAssertGreaterThan(sample.encodedBytes, 0)
        XCTAssertEqual(sample.receivedFrames, 1)
        XCTAssertEqual(sample.decodedFrames, 1)
        XCTAssertEqual(sample.presentedFrames, 1)
        XCTAssertEqual(sample.streamBacklogGrowth, 0)
        XCTAssertGreaterThanOrEqual(sample.maximumPresentationDelay, 0)
        session.touch(x: 0.5, y: 0.5, phase: .down)
        XCTAssertTrue(session.isTouchActive)
        await session.stopAndWait()
        XCTAssertFalse(session.isTouchActive)
        session.touch(x: 0.5, y: 0.5, phase: .down)
        XCTAssertFalse(session.isTouchActive, "Stopped streams cannot acquire a held touch")
        XCTAssertFalse(session.isStreaming); XCTAssertNil(session.screenshot())
        for _ in 0..<100 {
            if peer.received.suffix(2) == Data([10, 1]) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(peer.received.suffix(2), Data([10, 1]), "Explicit display override must be restored before the socket closes")
        let recorded = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
        XCTAssertTrue(recorded.split(separator: "\n").allSatisfy { $0.hasPrefix("-H 127.0.0.1 -P 49173 ") }, "Every command, including the long-running server and cleanup, must use the owned daemon")
        XCTAssertTrue(recorded.contains("forward --remove tcp:\(peer.port)"), recorded)
        XCTAssertTrue(recorded.contains("shell rm -f /data/local/tmp/nearby-scrcpy-"), recorded)
        XCTAssertFalse(recorded.contains("kill-server"))
    }
}

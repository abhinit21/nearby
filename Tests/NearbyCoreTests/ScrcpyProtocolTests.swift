import XCTest
import CoreVideo
@testable import NearbyCore

final class ScrcpyProtocolTests: XCTestCase {
    func testKeycodeGoldenPacket() {
        XCTAssertEqual(Array(ControlProtocol.keycode(3, down: true)), [0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(ControlProtocol.keycode(3, down: false)[1], 1)
        XCTAssertEqual(ControlProtocol.keycode(29, down: true, metaState: 0x1000).uint32BE(at: 10), 0x1000)
    }

    func testTouchMapsNormalizedEdgesToValidPixelsAndFinger() {
        let packet = ControlProtocol.touch(x: 1, y: -1, width: 1080, height: 2400, phase: .down)
        XCTAssertEqual(packet.count, 32)
        XCTAssertEqual(packet[1], 0)
        XCTAssertEqual(packet.uint64BE(at: 2), UInt64.max - 1)
        XCTAssertEqual(packet.uint32BE(at: 10), 1079)
        XCTAssertEqual(packet.uint32BE(at: 14), 0)
        XCTAssertEqual(packet.uint16BE(at: 18), 1080)
        XCTAssertEqual(packet.uint16BE(at: 20), 2400)
        XCTAssertEqual(packet.uint16BE(at: 22), UInt16.max)
        let release = ControlProtocol.touch(x: .nan, y: .infinity, width: 2400, height: 1080, phase: .up)
        XCTAssertEqual(release[1], 1)
        XCTAssertEqual(release.uint16BE(at: 22), 0)
        XCTAssertEqual(release.uint32BE(at: 10), 0)
    }

    func testScrollUsesScrcpyThreePointThreeSignedFixedPointRange() {
        let packet = ControlProtocol.scroll(x: 0.5, y: 0.5, width: 100, height: 200, dx: 16, dy: -16)
        XCTAssertEqual(packet.count, 21)
        XCTAssertEqual(packet.uint16BE(at: 13), 0x7fff)
        XCTAssertEqual(packet.uint16BE(at: 15), 0x8000)
        XCTAssertEqual(packet.uint32BE(at: 1), 50)
    }

    func testUnicodeTextIsTruncatedAtScalarBoundary() {
        let packet = ControlProtocol.text(String(repeating: "a", count: 299) + "😀")
        XCTAssertEqual(packet.uint32BE(at: 1), 299)
        XCTAssertNotNil(String(data: packet.dropFirst(5), encoding: .utf8))
        XCTAssertEqual(ControlProtocol.screenPower(false), Data([10, 0]))
        XCTAssertEqual(ControlProtocol.screenPower(true), Data([10, 1]))
    }

    func testClipboardPacketPreservesUnicodeAndPasteFlag() throws {
        let text = "Hello नमस्ते 😀"
        let packet = try ControlProtocol.clipboard(text, paste: true, sequence: 42)
        XCTAssertEqual(packet[0], 9)
        XCTAssertEqual(packet.uint64BE(at: 1), 42)
        XCTAssertEqual(packet[9], 1)
        XCTAssertEqual(packet.uint32BE(at: 10), UInt32(text.utf8.count))
        XCTAssertEqual(String(data: packet.dropFirst(14), encoding: .utf8), text)
    }

    func testFragmentedDeviceClipboardAndAcknowledgement() throws {
        var parser = ScrcpyDeviceMessageParser()
        let text = Data("Pixel 😀".utf8)
        var message = Data([0]); message.appendBE(UInt32(text.count)); message.append(text)
        var ack = Data([1]); ack.appendBE(UInt64(99))
        XCTAssertEqual(try parser.append(message.prefix(3)), [])
        XCTAssertEqual(try parser.append(Data(message.dropFirst(3)) + ack), [.clipboard("Pixel 😀"), .clipboardAcknowledgement(99)])
        XCTAssertEqual(try parser.append(Data()), [])
        XCTAssertThrowsError(try parser.append(Data([255])))
    }

    func testClipboardRejectsOversizeWithoutPartialUnicodeText() throws {
        let maximum = ClipboardTransferLimits.maximumTextBytes
        let exact = String(repeating: "a", count: maximum - 4) + "😀"
        let packet = try ControlProtocol.clipboard(exact, paste: true)
        XCTAssertEqual(packet.count, 1 << 18)
        XCTAssertEqual(String(data: packet.dropFirst(14), encoding: .utf8), exact)
        XCTAssertThrowsError(try ControlProtocol.clipboard(exact + "a", paste: true)) {
            XCTAssertEqual($0 as? ClipboardFailure, .tooLarge)
        }
    }

    func testFragmentedAcknowledgementsAndInvalidClipboardNeverExposeText() throws {
        var parser = ScrcpyDeviceMessageParser()
        var ack = Data([1]); ack.appendBE(UInt64.max)
        XCTAssertEqual(try parser.append(ack.prefix(6)), [])
        XCTAssertEqual(try parser.append(ack.dropFirst(6)), [.clipboardAcknowledgement(UInt64.max)])
        var invalid = Data([0]); invalid.appendBE(UInt32(2)); invalid.append(contentsOf: [0xff, 0xfe])
        XCTAssertThrowsError(try parser.append(invalid)) {
            XCTAssertEqual($0.localizedDescription, "The phone sent invalid clipboard text.")
        }
    }

    func testFrameFlagsAndOversizedPackets() throws {
        var bytes = Data(); bytes.appendBE(UInt64((1 << 62) | 123456)); bytes.appendBE(UInt32(1024))
        let header = try ScrcpyFrameHeader(bytes)
        XCTAssertFalse(header.isConfiguration); XCTAssertTrue(header.isKeyFrame)
        XCTAssertEqual(header.presentationTime, 123456); XCTAssertEqual(header.payloadSize, 1024)
        var oversized = Data(); oversized.appendBE(UInt64(0)); oversized.appendBE(UInt32.max)
        XCTAssertThrowsError(try ScrcpyFrameHeader(oversized))
        XCTAssertThrowsError(try ScrcpyFrameHeader(Data([0])))
    }

    func testMixedAnnexBStartCodesBecomeLengthPrefixedNALs() {
        let bytes = Data([0, 0, 0, 1, 0x67, 0x11, 0, 0, 1, 0x68, 0x22, 0, 0, 0, 1, 0x65, 0x33])
        let units = VideoDecoder.nalUnits(in: bytes)
        XCTAssertEqual(units, [Data([0x67, 0x11]), Data([0x68, 0x22]), Data([0x65, 0x33])])
        XCTAssertEqual(VideoDecoder.lengthPrefixed(units), Data([0, 0, 0, 2, 0x67, 0x11, 0, 0, 0, 2, 0x68, 0x22, 0, 0, 0, 2, 0x65, 0x33]))
        XCTAssertEqual(VideoDecoder.nalUnits(in: Data([0x65, 0x22])), [])
    }
}

@MainActor final class ScrcpyLifecycleTests: XCTestCase {
    private final class DecodedFrame: @unchecked Sendable {
        private let lock = NSLock()
        private var dimensions: [Int]?
        func record(_ buffer: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let blue = CVPixelBufferGetBaseAddress(buffer).map { $0.load(as: UInt8.self) } ?? 0
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            lock.lock(); dimensions = [CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), Int(blue)]; lock.unlock()
        }
        var value: [Int]? { lock.lock(); defer { lock.unlock() }; return dimensions }
    }

    func testNativeVideoToolboxDecodesKnownH264AccessUnit() async throws {
        // Generated solid-blue64×96 baseline H.264 fixture; no user/device image.
        let data = Data(base64Encoded: "AAAAAWdCwAraENsBEAAAAwAQAAADACjxImoAAAABaM4PyAAAAWWIhDoRigACMXHAAEPKOAAIBcnJyddddddddddddddddddddeA=")!
        var bytes = Data(); bytes.appendBE(UInt64(1 << 62)); bytes.appendBE(UInt32(data.count))
        let decoded = DecodedFrame()
        let decoder = VideoDecoder { decoded.record($0) }
        defer { decoder.invalidate() }
        try decoder.decode(data, header: ScrcpyFrameHeader(bytes))
        for _ in 0..<100 {
            if decoded.value != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let frame = try XCTUnwrap(decoded.value, "VideoToolbox did not produce a frame")
        XCTAssertEqual(Array(frame.prefix(2)), [64, 96])
        XCTAssertGreaterThan(frame[2], 200, "Fixture should decode to a blue BGRA pixel")
    }

    func testUnsupportedAudioAndMismatchedVersionFailBeforeADB() async {
        let adb = ADBClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let missing = URL(fileURLWithPath: "/nonexistent/scrcpy-server")
        let mismatch = ScrcpySession(adb: adb, serverURL: missing, serverVersion: "2.1")
        do { try await mismatch.start(serial: "test", options: StreamOptions()); XCTFail("Expected version rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("3.3.4")) }
        let audio = ScrcpySession(adb: adb, serverURL: missing, serverVersion: "3.3.4")
        do { try await audio.start(serial: "test", options: StreamOptions(audio: true)); XCTFail("Expected audio rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("audio")) }
        XCTAssertFalse(audio.isStreaming)
        XCTAssertNil(audio.screenshot())
    }

    func testCanceledStartupRemovesOnlyOwnedForward() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NearbyEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let calls = folder.appendingPathComponent("calls")
        let executable = folder.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(calls.path)'
        case "$3" in
          forward) if [ "$4" = "tcp:0" ]; then sleep 0.15; echo 19081; fi ;;
          shell) if [ "$4" != "rm" ]; then sleep 2; fi ;;
        esac
        exit 0
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let server = folder.appendingPathComponent("server")
        try Data([0]).write(to: server)
        let session = ScrcpySession(adb: ADBClient(executableURL: executable), serverURL: server, serverVersion: "3.3.4")
        let startup = Task { try await session.start(serial: "test", options: StreamOptions()) }
        for _ in 0..<100 {
            if (try? String(contentsOf: calls, encoding: .utf8))?.contains("forward tcp:0") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        startup.cancel(); session.stop()
        do { try await startup.value; XCTFail("Canceled startup must not succeed") } catch {}
        await session.stopAndWait()
        let recorded = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
        XCTAssertTrue(recorded.contains("forward --remove tcp:19081"), recorded)
        XCTAssertFalse(recorded.contains("kill-server"))
        XCTAssertFalse(recorded.contains("--remove-all"))
        XCTAssertFalse(session.isStreaming)
    }
}

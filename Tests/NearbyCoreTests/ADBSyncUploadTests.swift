import XCTest
import Darwin
@testable import NearbyCore

private final class SpecimenSyncPeer: @unchecked Sendable {
    enum Reply { case success, noSpace, earlyNoSpace, serviceFailure, disconnect, wait }
    private let lock = NSLock()
    private let listener: Int32
    private var peer: Int32 = -1
    private var stopped = false
    private var received = Data()
    private var services: [String] = []
    private var path: String?
    private var maxChunk = 0
    private var sawDone = false
    private let reply: Reply
    private let fragmentedResponses: Bool
    let port: Int

    init(reply: Reply = .success, fragmentedResponses: Bool = false) throws {
        self.reply = reply; self.fragmentedResponses = fragmentedResponses
        let listenerFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        listener = listenerFD
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(listenerFD, 1) == 0 else { throw FileTransferError.protocolFailure }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(listenerFD, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        DispatchQueue.global(qos: .userInitiated).async { [self] in serve() }
    }
    var snapshot: (Data, [String], String?, Int, Bool) {
        lock.lock(); defer { lock.unlock() }; return (received, services, path, maxChunk, sawDone)
    }
    func stop() {
        lock.lock(); stopped = true
        Darwin.shutdown(listener, SHUT_RDWR)
        if peer >= 0 { Darwin.shutdown(peer, SHUT_RDWR) }
        lock.unlock()
    }
    private func read(_ count: Int, _ fd: Int32) -> Data? {
        var data = Data(count: count), offset = 0
        while offset < count {
            let got = data.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            guard got > 0 else { return nil }; offset += got
        }
        return data
    }
    private func write(_ data: Data, _ fd: Int32) -> Bool {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard sent > 0 else { return false }; offset += sent
        }
        return true
    }
    private func respond(_ data: Data, _ fd: Int32) -> Bool {
        guard fragmentedResponses else { return write(data, fd) }
        // Each one-byte TCP write is separated so headers, lengths, and payloads
        // cannot be assumed to arrive in one recv, even on a fast loopback link.
        for byte in data {
            guard write(Data([byte]), fd) else { return false }
            usleep(1_000)
        }
        return true
    }
    private func little(_ data: Data) -> UInt32 {
        data.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }
    private func packet(_ id: String, _ length: UInt32) -> Data {
        var data = Data(id.utf8), value = length.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }; return data
    }
    private func serve() {
        let fd = Darwin.accept(listener, nil, nil)
        defer { Darwin.close(listener) }
        guard fd >= 0 else { return }
        lock.lock(); peer = fd; let shouldStop = stopped; lock.unlock()
        defer { lock.lock(); peer = -1; Darwin.close(fd); lock.unlock() }
        if shouldStop { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        if fragmentedResponses {
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        }
        for _ in 0..<2 {
            guard let prefix = read(4, fd), let length = Int(String(decoding: prefix, as: UTF8.self), radix: 16),
                  let name = read(length, fd) else { return }
            lock.lock(); services.append(String(decoding: name, as: UTF8.self)); lock.unlock()
            if reply == .serviceFailure {
                let error = Data("device offline".utf8)
                _ = respond(Data(("FAIL" + String(format: "%04x", error.count)).utf8) + error, fd)
                return
            }
            guard respond(Data("OKAY".utf8), fd) else { return }
        }
        guard let header = read(8, fd), String(decoding: header.prefix(4), as: UTF8.self) == "SEND",
              let destination = read(Int(little(Data(header.suffix(4)))), fd) else { return }
        lock.lock(); path = String(decoding: destination, as: UTF8.self); lock.unlock()
        if reply == .disconnect { return }
        if reply == .wait { _ = read(1, fd); while read(1, fd) != nil {} ; return }
        while let header = read(8, fd) {
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            let count = little(Data(header.suffix(4)))
            if id == "DONE" { lock.lock(); sawDone = true; lock.unlock(); break }
            guard id == "DATA", count <= 65_536, let bytes = read(Int(count), fd) else { return }
            lock.lock(); received.append(bytes); maxChunk = max(maxChunk, Int(count)); lock.unlock()
            if reply == .earlyNoSpace {
                let message = Data("write failed: No space left on device".utf8)
                _ = respond(packet("FAIL", UInt32(message.count)) + message, fd)
                // Intentionally do not drain DATA. An uploader that only reads
                // the reply after DONE would block/misclassify this failure.
                usleep(500_000)
                return
            }
        }
        if reply == .noSpace {
            let message = Data("write failed: No space left on device".utf8)
            _ = respond(packet("FAIL", UInt32(message.count)) + message, fd)
        } else { _ = respond(packet("OKAY", 0), fd) }
    }
}

private final class TransferByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func append(_ value: Int64) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [Int64] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class TransferSourceMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted = false
    private var succeeded = false
    func mutate(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        guard !attempted else { return }; attempted = true
        let fd = Darwin.open(url.path, O_WRONLY)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var byte: UInt8 = 9
        succeeded = Darwin.pwrite(fd, &byte, 1, 200_000) == 1
    }
    var didMutate: Bool { lock.lock(); defer { lock.unlock() }; return succeeded }
}

@MainActor final class ADBSyncUploadTests: XCTestCase {
    private func source(_ data: Data) throws -> (URL, FileTransferSource) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NearbySyncSpecimen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sample Unicode 你好.txt")
        try data.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (file, try FileTransferSource(url: file))
    }

    func testRealSocketFramingChunksUnicodePathAndExactAcknowledgedBytes() async throws {
        let bytes = Data((0..<190_000).map { UInt8($0 % 251) })
        let (_, source) = try source(bytes)
        let peer = try SpecimenSyncPeer(); defer { peer.stop() }
        let progress = TransferByteCounter()
        let upload = ADBSyncUpload(port: peer.port, serial: "paired-synthetic:5555", source: source,
                                   remotePath: "/sdcard/Download/.nearby-transfer-α/payload.partial", progress: { progress.append($0) })
        try await upload.run()
        let actual = peer.snapshot
        XCTAssertEqual(actual.0, bytes)
        XCTAssertEqual(actual.1, ["host:transport:paired-synthetic:5555", "sync:"])
        XCTAssertEqual(actual.2, "/sdcard/Download/.nearby-transfer-α/payload.partial,33152")
        XCTAssertEqual(actual.3, 65_536)
        XCTAssertTrue(actual.4)
        XCTAssertEqual(progress.snapshot.first, 0); XCTAssertEqual(progress.snapshot.last, Int64(bytes.count))
        XCTAssertEqual(progress.snapshot, progress.snapshot.sorted())
    }

    func testEmptyFileStillRequiresDoneAndAck() async throws {
        let (_, source) = try source(Data())
        let peer = try SpecimenSyncPeer(); defer { peer.stop() }
        let upload = ADBSyncUpload(port: peer.port, serial: "synthetic", source: source, remotePath: "/own/partial", progress: { _ in })
        try await upload.run()
        XCTAssertTrue(peer.snapshot.4)
        XCTAssertTrue(peer.snapshot.0.isEmpty)
    }

    func testDeviceNoSpaceIsNotReportedAsSuccessDespiteSendingAllBytes() async throws {
        let (_, source) = try source(Data(repeating: 2, count: 70_000))
        let peer = try SpecimenSyncPeer(reply: .noSpace); defer { peer.stop() }
        let upload = ADBSyncUpload(port: peer.port, serial: "synthetic", source: source, remotePath: "/own/partial", progress: { _ in })
        do { try await upload.run(); XCTFail("Device FAIL must propagate") }
        catch { XCTAssertEqual(error as? FileTransferError, .insufficientStorage) }
    }

    func testByteFragmentedServiceAndSyncSuccessRepliesAreReassembled() async throws {
        let data = Data(repeating: 1, count: 150_000)
        let (_, source) = try source(data)
        let peer = try SpecimenSyncPeer(fragmentedResponses: true); defer { peer.stop() }
        let upload = ADBSyncUpload(port: peer.port, serial: "synthetic", source: source, remotePath: "/own/partial", progress: { _ in })
        try await upload.run()
        XCTAssertEqual(peer.snapshot.0, data)
        XCTAssertTrue(peer.snapshot.4)
    }

    func testByteFragmentedServiceFailAndSyncFailRetainUsefulErrorMapping() async throws {
        let (_, source) = try source(Data(repeating: 2, count: 70_000))
        let servicePeer = try SpecimenSyncPeer(reply: .serviceFailure, fragmentedResponses: true)
        defer { servicePeer.stop() }
        let service = ADBSyncUpload(port: servicePeer.port, serial: "synthetic", source: source, remotePath: "/own/partial", progress: { _ in })
        do { try await service.run(); XCTFail("Fragmented service FAIL must propagate") }
        catch { XCTAssertEqual(error as? FileTransferError, .interrupted) }
        XCTAssertTrue(servicePeer.snapshot.0.isEmpty)
        let syncPeer = try SpecimenSyncPeer(reply: .noSpace, fragmentedResponses: true)
        defer { syncPeer.stop() }
        let sync = ADBSyncUpload(port: syncPeer.port, serial: "synthetic", source: source, remotePath: "/own/partial", progress: { _ in })
        do { try await sync.run(); XCTFail("Fragmented SYNC FAIL must propagate") }
        catch { XCTAssertEqual(error as? FileTransferError, .insufficientStorage) }
    }

    func testNoSpaceDuringDataStopsBeforeDoneEvenWhenDeviceStopsReading() async throws {
        let data = Data(repeating: 3, count: 16 * 1_024 * 1_024)
        let (_, source) = try source(data)
        let peer = try SpecimenSyncPeer(reply: .earlyNoSpace, fragmentedResponses: true)
        defer { peer.stop() }
        let progress = TransferByteCounter()
        let upload = ADBSyncUpload(port: peer.port, serial: "synthetic", source: source,
                                   remotePath: "/own/partial", progress: { progress.append($0) })
        let began = ProcessInfo.processInfo.systemUptime
        do { try await upload.run(); XCTFail("An early FAIL must stop DATA and retain ENOSPC") }
        catch { XCTAssertEqual(error as? FileTransferError, .insufficientStorage) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        XCTAssertEqual(peer.snapshot.0.count, 65_536)
        XCTAssertFalse(peer.snapshot.4)
        XCTAssertLessThan(progress.snapshot.last ?? Int64.max, Int64(data.count))
    }

    func testPacedDataRetainsEarlyFailureWhileWaitingForMoreBudget() async throws {
        let (_, source) = try source(Data(repeating: 3, count: 3 * 65_536))
        let peer = try SpecimenSyncPeer(reply: .earlyNoSpace, fragmentedResponses: true)
        defer { peer.stop() }
        // The next DATA chunk would take over eighteen hours to earn. A remote
        // FAIL must still surface immediately, including its fragmented message.
        let pacing = UploadPacing(bytesPerSecond: 1)
        let upload = ADBSyncUpload(port: peer.port, serial: "synthetic", source: source,
                                   remotePath: "/own/partial", pacing: pacing, progress: { _ in })
        let began = ProcessInfo.processInfo.systemUptime
        do { try await upload.run(); XCTFail("A paced DATA wait must observe remote FAIL") }
        catch { XCTAssertEqual(error as? FileTransferError, .insufficientStorage) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        XCTAssertEqual(peer.snapshot.0.count, 65_536)
        XCTAssertFalse(peer.snapshot.4)
    }

    func testCancellationInterruptsPacingWithoutWaitingForBudget() async throws {
        let (_, source) = try source(Data(repeating: 3, count: 3 * 65_536))
        let peer = try SpecimenSyncPeer(); defer { peer.stop() }
        let upload = ADBSyncUpload(port: peer.port, serial: "synthetic", source: source,
                                   remotePath: "/own/partial", pacing: UploadPacing(bytesPerSecond: 1), progress: { _ in })
        let task = Task { try await upload.run() }
        for _ in 0..<200 {
            if peer.snapshot.0.count == 65_536 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(peer.snapshot.0.count, 65_536)
        let began = ProcessInfo.processInfo.systemUptime
        upload.cancel()
        do { try await task.value; XCTFail("Cancellation must interrupt a pacing wait") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        XCTAssertFalse(peer.snapshot.4)
    }

    func testLiftingRateLimitAppliesToActiveUploadAndDoesNotDelayDone() async throws {
        let data = Data(repeating: 3, count: 2 * 65_536)
        let (_, source) = try source(data)
        let peer = try SpecimenSyncPeer(); defer { peer.stop() }
        let pacing = UploadPacing(bytesPerSecond: 1)
        let upload = ADBSyncUpload(port: peer.port, serial: "synthetic", source: source,
                                   remotePath: "/own/partial", pacing: pacing, progress: { _ in })
        let task = Task { try await upload.run() }
        for _ in 0..<200 {
            if peer.snapshot.0.count == 65_536 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(peer.snapshot.0.count, 65_536)
        let began = ProcessInfo.processInfo.systemUptime
        pacing.setRateLimit(bytesPerSecond: nil)
        try await task.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        XCTAssertEqual(peer.snapshot.0, data)
        XCTAssertTrue(peer.snapshot.4)
    }

    func testPacedUploadSendsBurstThenWaitsForSourceByteBudget() async throws {
        let data = Data(repeating: 3, count: 2 * 65_536)
        let (_, source) = try source(data)
        let peer = try SpecimenSyncPeer(); defer { peer.stop() }
        let upload = ADBSyncUpload(port: peer.port, serial: "synthetic", source: source,
                                   remotePath: "/own/partial", pacing: UploadPacing(bytesPerSecond: 131_072), progress: { _ in })
        let began = ProcessInfo.processInfo.systemUptime
        try await upload.run()
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - began, 0.48)
        XCTAssertEqual(peer.snapshot.0, data)
        XCTAssertTrue(peer.snapshot.4)
    }

    func testSameSizeSourceMutationBetweenReadChunksPreventsCommitDone() async throws {
        let data = Data(repeating: 4, count: 256 * 1_024)
        let (url, source) = try source(data)
        let peer = try SpecimenSyncPeer(); defer { peer.stop() }
        let mutation = TransferSourceMutation()
        let upload = ADBSyncUpload(port: peer.port, serial: "synthetic", source: source, remotePath: "/own/partial") { bytes in
            if bytes == 65_536 { mutation.mutate(url) }
        }
        do { try await upload.run(); XCTFail("Changed content must fail even when size is unchanged") }
        catch { XCTAssertEqual(error as? FileTransferError, .changedSource) }
        XCTAssertTrue(mutation.didMutate, "Mutation must happen synchronously after a real DATA chunk")
        XCTAssertEqual(try Data(contentsOf: url).count, data.count)
        XCTAssertFalse(peer.snapshot.4, "A changed source must never send final DONE")
    }

    func testDisconnectAndCancellationStopOnlyThisSocket() async throws {
        let (_, source) = try source(Data(repeating: 3, count: 500_000))
        let peer = try SpecimenSyncPeer(reply: .disconnect); defer { peer.stop() }
        let disconnected = ADBSyncUpload(port: peer.port, serial: "synthetic", source: source, remotePath: "/own/partial", progress: { _ in })
        do { try await disconnected.run(); XCTFail("Disconnect must fail") }
        catch { XCTAssertEqual(error as? FileTransferError, .interrupted) }
        let waiting = try SpecimenSyncPeer(reply: .wait); defer { waiting.stop() }
        let upload = ADBSyncUpload(port: waiting.port, serial: "synthetic", source: source, remotePath: "/own/partial", progress: { _ in })
        let task = Task { try await upload.run() }
        for _ in 0..<100 {
            if waiting.snapshot.2 != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let began = ProcessInfo.processInfo.systemUptime
        upload.cancel()
        do { try await task.value; XCTFail("Cancellation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
    }

    func testChangedSourceAndSymlinkCannotBeUploaded() async throws {
        let (url, original) = try source(Data([1]))
        try Data([1, 2]).write(to: url)
        let changed = ADBSyncUpload(port: 45678, serial: "synthetic", source: original, remotePath: "/own/partial", progress: { _ in })
        do { try await changed.run(); XCTFail("Changed size must fail before any connection") }
        catch { XCTAssertEqual(error as? FileTransferError, .changedSource) }
        let target = url.deletingLastPathComponent().appendingPathComponent("target")
        try Data([3]).write(to: target)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let linked = ADBSyncUpload(port: 45678, serial: "synthetic", source: original, remotePath: "/own/partial", progress: { _ in })
        do { try await linked.run(); XCTFail("Symbolic link must fail") }
        catch { XCTAssertEqual(error as? FileTransferError, .regularFilesOnly) }
    }

    func testSharedADBPortIsRejectedBeforeConnection() async throws {
        let (_, source) = try source(Data([1]))
        let upload = ADBSyncUpload(port: 5037, serial: "synthetic", source: source, remotePath: "/own/partial", progress: { _ in })
        do { try await upload.run(); XCTFail("Shared daemon must not be used") }
        catch { XCTAssertEqual(error as? FileTransferError, .unavailable) }
    }
}

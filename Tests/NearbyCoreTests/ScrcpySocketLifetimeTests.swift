import XCTest
import Darwin
@testable import NearbyCore

private enum SocketLifetimeTestError: Error { case systemCall(Int32), leaseNotObserved, exactReuseUnavailable }

/// Stops an operation after its fd lease exists but before its first syscall.
private final class DescriptorLeaseBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: ScrcpySocket.IOOperation
    private let acquired = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private var descriptors: (original: Int32, lease: Int32)?

    init(_ operation: ScrcpySocket.IOOperation) { self.operation = operation }

    func observe(_ operation: ScrcpySocket.IOOperation, original: Int32, lease: Int32) {
        guard operation == self.operation else { return }
        lock.lock(); descriptors = (original, lease); lock.unlock()
        acquired.signal()
        _ = released.wait(timeout: .now() + 5)
    }

    func waitForLease() throws -> (original: Int32, lease: Int32) {
        guard acquired.wait(timeout: .now() + 2) == .success else { throw SocketLifetimeTestError.leaseNotObserved }
        lock.lock(); defer { lock.unlock() }
        guard let descriptors else { throw SocketLifetimeTestError.leaseNotObserved }
        return descriptors
    }

    func release() { released.signal() }
}

private final class SocketReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var failed = false
    func record(_ value: Data) { lock.lock(); self.value = value; lock.unlock() }
    func recordFailure() { lock.lock(); failed = true; lock.unlock() }
    var snapshot: (data: Data?, failed: Bool) { lock.lock(); defer { lock.unlock() }; return (value, failed) }
}

private final class SocketLifetimeListener {
    let descriptor: Int32
    let port: UInt16
    init() throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        descriptor = listener
        guard listener >= 0 else { throw SocketLifetimeTestError.systemCall(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else {
            let code = errno; Darwin.close(listener); throw SocketLifetimeTestError.systemCall(code)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(listener, $0, &length) }
        }
        guard named == 0 else {
            let code = errno; Darwin.close(listener); throw SocketLifetimeTestError.systemCall(code)
        }
        port = UInt16(bigEndian: address.sin_port)
    }
    deinit { Darwin.close(descriptor) }
    func accept() throws -> Int32 {
        let peer = Darwin.accept(descriptor, nil, nil)
        guard peer >= 0 else { throw SocketLifetimeTestError.systemCall(errno) }
        return peer
    }
}

/// Holds a separate live connection before the original fd closes. fcntl then
/// reserves that exact freed integer without ever overwriting a foreign fd.
private final class ReplacementSocketPair {
    let source: Int32
    let peer: Int32
    private(set) var reused: Int32 = -1
    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SocketLifetimeTestError.systemCall(errno)
        }
        source = descriptors[0]; peer = descriptors[1]
    }
    func reuse(_ original: Int32) throws {
        let duplicate = fcntl(source, F_DUPFD_CLOEXEC, original)
        guard duplicate >= 0 else { throw SocketLifetimeTestError.systemCall(errno) }
        guard duplicate == original else {
            Darwin.close(duplicate)
            throw SocketLifetimeTestError.exactReuseUnavailable
        }
        reused = duplicate
    }
    deinit {
        if reused >= 0 { Darwin.close(reused) }
        Darwin.close(source); Darwin.close(peer)
    }
}

final class ScrcpySocketLifetimeTests: XCTestCase {
    func testOldControlWriterCannotSendIntoReusedDescriptor() throws {
        let listener = try SocketLifetimeListener()
        let barrier = DescriptorLeaseBarrier(.writeExactly)
        defer { barrier.release() }
        let socket = try ScrcpySocket(port: listener.port, descriptorLeaseObserver: { operation, original, lease in
            barrier.observe(operation, original: original, lease: lease)
        })
        defer { socket.close() }
        let oldPeer = try listener.accept()
        defer { Darwin.close(oldPeer) }
        let finished = expectation(description: "Old writer fails against its shutdown endpoint")
        socket.send(Data("Nearby old clipboard sample".utf8)) { _ in finished.fulfill() }
        let descriptors = try barrier.waitForLease()
        XCTAssertNotEqual(descriptors.original, descriptors.lease)
        let replacement = try ReplacementSocketPair()
        socket.close()
        try replacement.reuse(descriptors.original)
        XCTAssertEqual(replacement.reused, descriptors.original)
        barrier.release()
        wait(for: [finished], timeout: 2)
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = Darwin.recv(replacement.peer, &bytes, bytes.count, MSG_DONTWAIT)
        let receiveError = errno
        XCTAssertEqual(count, -1, "An old control write must never reach the new peer")
        XCTAssertTrue(receiveError == EAGAIN || receiveError == EWOULDBLOCK)
        // Demonstrate the replacement itself is healthy, rather than merely
        // observing no bytes because a new channel happened to be broken.
        let marker = Data("Nearby replacement writer marker".utf8)
        let sent = marker.withUnsafeBytes { Darwin.send(replacement.peer, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(sent, marker.count)
        let received = Darwin.recv(replacement.reused, &bytes, bytes.count, MSG_DONTWAIT)
        XCTAssertEqual(received, marker.count)
        if received >= 0 { XCTAssertEqual(Data(bytes.prefix(received)), marker) }
    }

    func testOldExactReaderCannotConsumeMarkerFromReusedDescriptor() throws {
        try checkOldReaderCannotConsumeReplacementMarker(operation: .readExactly)
    }

    func testOldAvailableReaderCannotConsumeMarkerFromReusedDescriptor() throws {
        try checkOldReaderCannotConsumeReplacementMarker(operation: .readAvailable)
    }

    private func checkOldReaderCannotConsumeReplacementMarker(operation: ScrcpySocket.IOOperation) throws {
        let listener = try SocketLifetimeListener()
        let barrier = DescriptorLeaseBarrier(operation)
        defer { barrier.release() }
        let socket = try ScrcpySocket(port: listener.port, descriptorLeaseObserver: { operation, original, lease in
            barrier.observe(operation, original: original, lease: lease)
        })
        defer { socket.close() }
        let oldPeer = try listener.accept()
        defer { Darwin.close(oldPeer) }
        let marker = Data("Nearby replacement reader marker".utf8)
        let result = SocketReadResult()
        let finished = expectation(description: "Old reader fails against its shutdown endpoint")
        DispatchQueue.global().async {
            do {
                let data = try operation == .readExactly ? socket.readExactly(marker.count) : socket.readAvailable()
                result.record(data)
            } catch { result.recordFailure() }
            finished.fulfill()
        }
        let descriptors = try barrier.waitForLease()
        XCTAssertNotEqual(descriptors.original, descriptors.lease)
        let replacement = try ReplacementSocketPair()
        socket.close()
        try replacement.reuse(descriptors.original)
        XCTAssertEqual(replacement.reused, descriptors.original)
        let sent = marker.withUnsafeBytes { Darwin.send(replacement.peer, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(sent, marker.count)
        barrier.release()
        wait(for: [finished], timeout: 2)
        XCTAssertTrue(result.snapshot.failed)
        XCTAssertNil(result.snapshot.data, "An old reader must never consume another session's bytes")
        var bytes = [UInt8](repeating: 0, count: 128)
        let received = Darwin.recv(replacement.reused, &bytes, bytes.count, MSG_DONTWAIT)
        XCTAssertEqual(received, marker.count, "The new peer's marker must remain available to its own reader")
        if received >= 0 { XCTAssertEqual(Data(bytes.prefix(received)), marker) }
    }
}

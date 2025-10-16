import XCTest
import Combine
@testable import NearbyCore

private actor SpecimenTransferTransport: FileTransferTransport {
    enum Behavior: Sendable { case success, storage, interrupted, waitForCancellation, gatedCommit }
    var behavior: Behavior
    var cleanupFails = false
    var calls: [String] = []
    var commitStarted = false
    var commitReleased = false
    init(_ behavior: Behavior = .success) { self.behavior = behavior }
    func setBehavior(_ next: Behavior) { behavior = next }
    func setCleanupFails(_ value: Bool) { cleanupFails = value }
    func releaseCommit() { commitReleased = true }
    func prepare(_ ownership: FileTransferOwnership, byteCount: Int64) async throws {
        calls.append("prepare:" + ownership.deviceID)
        if behavior == .storage { throw FileTransferError.insufficientStorage }
    }
    func upload(_ source: FileTransferSource, ownership: FileTransferOwnership, progress: @escaping @Sendable (Int64) -> Void) async throws {
        calls.append("upload:" + source.name)
        progress(source.byteCount / 2)
        switch behavior {
        case .interrupted: throw FileTransferError.interrupted
        case .waitForCancellation: try await Task.sleep(for: .seconds(60))
        default: break
        }
        progress(source.byteCount)
    }
    func commit(_ ownership: FileTransferOwnership, preferredName: String, byteCount: Int64) async throws -> String {
        calls.append("commit:" + preferredName); commitStarted = true
        if behavior == .gatedCommit {
            while !commitReleased { try await Task.sleep(for: .milliseconds(10)) }
        }
        return preferredName + " (saved)"
    }
    func cleanup(_ ownership: FileTransferOwnership) async throws {
        calls.append("cleanup:" + ownership.deviceID)
        if cleanupFails { throw FileTransferError.interrupted }
    }
}

@MainActor
final class FileTransferTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearbyTransferTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func file(_ root: URL, _ name: String = "Sample 你好 🌲.txt") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("Nearby harmless sample text.\n".utf8).write(to: url)
        return url
    }
    private func coordinator(_ root: URL, _ transport: SpecimenTransferTransport) -> FileTransferCoordinator {
        FileTransferCoordinator(journalURL: root.appendingPathComponent("cleanup.json")) { _, _ in transport }
    }
    private func connect(_ queue: FileTransferCoordinator, _ device: String = "paired-pixel", id: UUID = UUID()) async {
        await queue.setSession(FileTransferSession(id: id, deviceID: device, serial: "new-endpoint:5555"), adb: nil)
    }
    private func settle(_ queue: FileTransferCoordinator) async throws {
        for _ in 0..<300 {
            if !queue.isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Transfer queue did not settle")
    }

    func testUnicodeMultipleFilesReportAllStatesAndRequireAcknowledgedCommit() async throws {
        let root = try fixture(), transport = SpecimenTransferTransport()
        let queue = coordinator(root, transport)
        await connect(queue)
        var states: Set<FileTransferState> = []
        let observation = queue.$items.sink { states.formUnion($0.map(\.state)) }
        queue.enqueue([try file(root), try file(root, "second file.txt")])
        try await settle(queue)
        XCTAssertEqual(queue.items.map(\.state), [.completed, .completed])
        XCTAssertTrue(states.isSuperset(of: [.queued, .preparing, .transferring, .finalizing, .completed]))
        XCTAssertTrue(queue.items.allSatisfy { $0.progress == 1 && $0.completedBytes == $0.byteCount })
        XCTAssertEqual(queue.items.first?.destinationName, "Sample 你好 🌲.txt (saved)")
        XCTAssertFalse(queue.cleanupPending)
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("commit:") }.count, 2)
        XCTAssertEqual(calls.filter { $0.hasPrefix("cleanup:") }.count, 2)
        withExtendedLifetime(observation) {}
    }

    func testNoActiveSessionAndNonRegularSourcesAreVisibleFailures() async throws {
        let root = try fixture(), transport = SpecimenTransferTransport(), source = try file(root)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let queue = coordinator(root, transport)
        queue.enqueue([source, root, link])
        XCTAssertEqual(queue.items.map(\.state), [.failed, .failed, .failed])
        XCTAssertEqual(queue.items[0].errorMessage, FileTransferError.unavailable.localizedDescription)
        XCTAssertEqual(queue.items[1].errorMessage, FileTransferError.regularFilesOnly.localizedDescription)
        XCTAssertEqual(queue.items[2].errorMessage, FileTransferError.regularFilesOnly.localizedDescription)
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testStorageFailureIsUsefulAndRetryIsExplicitPerFile() async throws {
        let root = try fixture(), transport = SpecimenTransferTransport(.storage), queue = coordinator(root, transport)
        await connect(queue)
        queue.enqueue([try file(root), try file(root, "second.txt")])
        try await settle(queue)
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .failed && $0.errorMessage == FileTransferError.insufficientStorage.localizedDescription })
        await transport.setBehavior(.success)
        let retryID = queue.items[0].id
        queue.retry(retryID)
        try await settle(queue)
        XCTAssertEqual(queue.items.map(\.state), [.completed, .failed])
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("upload:") }.count, 1)
    }

    func testCancellationStopsActiveAndQueuedFilesAndCleansOnlyOwnedToken() async throws {
        let root = try fixture(), transport = SpecimenTransferTransport(.waitForCancellation), queue = coordinator(root, transport)
        await connect(queue)
        queue.enqueue([try file(root), try file(root, "queued.txt")])
        for _ in 0..<100 {
            if queue.items[0].state == .transferring { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        queue.cancel()
        try await settle(queue)
        XCTAssertEqual(queue.items.map(\.state), [.cancelled, .cancelled])
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("upload:") }.count, 1)
        XCTAssertEqual(calls.filter { $0.hasPrefix("cleanup:") }.count, 1)
        XCTAssertFalse(calls.contains { $0.hasPrefix("commit:") })
        XCTAssertFalse(queue.cleanupPending)
    }

    func testCancelDuringAtomicSaveFinishesCurrentFileAndCancelsRest() async throws {
        let root = try fixture(), transport = SpecimenTransferTransport(.gatedCommit), queue = coordinator(root, transport)
        await connect(queue)
        queue.enqueue([try file(root), try file(root, "queued.txt")])
        for _ in 0..<100 {
            if await transport.commitStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(queue.items[0].state, .finalizing)
        queue.cancel()
        XCTAssertEqual(queue.items[0].state, .finalizing)
        await transport.releaseCommit()
        try await settle(queue)
        XCTAssertEqual(queue.items.map(\.state), [.completed, .cancelled])
    }

    func testNewDropDuringCancellationHasExplicitRetryableFailure() async throws {
        let root = try fixture(), transport = SpecimenTransferTransport(.gatedCommit), queue = coordinator(root, transport)
        await connect(queue)
        queue.enqueue([try file(root)])
        for _ in 0..<100 {
            if await transport.commitStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        queue.cancel()
        XCTAssertFalse(queue.canAcceptFiles)
        queue.enqueue([try file(root, "new drop.txt")])
        XCTAssertEqual(queue.items[1].state, .failed)
        XCTAssertEqual(queue.items[1].errorMessage, FileTransferError.cancellationPending.localizedDescription)
        await transport.releaseCommit()
        try await settle(queue)
        XCTAssertEqual(queue.items.map(\.state), [.completed, .failed])
        XCTAssertTrue(queue.canAcceptFiles)
        await transport.setBehavior(.success)
        queue.retry(queue.items[1].id)
        try await settle(queue)
        XCTAssertEqual(queue.items.map(\.state), [.completed, .completed])
    }

    func testDisconnectStopsQueueAndReconnectDoesNotRestartIt() async throws {
        let root = try fixture(), transport = SpecimenTransferTransport(.waitForCancellation), queue = coordinator(root, transport)
        await connect(queue)
        queue.enqueue([try file(root), try file(root, "queued.txt")])
        for _ in 0..<100 {
            if queue.items[0].state == .transferring { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await queue.setSession(nil, adb: nil)
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .failed })
        await transport.setBehavior(.success)
        await connect(queue)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(queue.items.map(\.state), [.failed, .failed])
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("upload:") }.count, 1)
    }

    func testCleanupJournalSurvivesInterruptionAndOnlyCleansSameDevice() async throws {
        let root = try fixture(), transport = SpecimenTransferTransport(.interrupted)
        await transport.setCleanupFails(true)
        let first = coordinator(root, transport)
        await connect(first)
        first.enqueue([try file(root)])
        try await settle(first)
        XCTAssertTrue(first.cleanupPending)
        let records = try JSONDecoder().decode([FileTransferOwnership].self, from: Data(contentsOf: root.appendingPathComponent("cleanup.json")))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.deviceID, "paired-pixel")
        await first.setSession(nil, adb: nil)
        let secondTransport = SpecimenTransferTransport()
        let second = coordinator(root, secondTransport)
        await connect(second, "different-device")
        XCTAssertTrue(second.cleanupPending)
        let differentDeviceCalls = await secondTransport.calls
        XCTAssertTrue(differentDeviceCalls.isEmpty)
        await connect(second, "paired-pixel")
        XCTAssertFalse(second.cleanupPending)
        let sameDeviceCalls = await secondTransport.calls
        XCTAssertEqual(sameDeviceCalls, ["cleanup:paired-pixel"])
        XCTAssertTrue(second.items.isEmpty, "Recovered cleanup must not recreate or restart payloads")
    }

    func testJournalWriteFailurePreventsAllRemoteWork() async throws {
        let root = try fixture(), blocker = try file(root, "not-a-directory"), transport = SpecimenTransferTransport()
        let queue = FileTransferCoordinator(journalURL: blocker.appendingPathComponent("cleanup.json")) { _, _ in transport }
        await connect(queue)
        queue.enqueue([try file(root)])
        try await settle(queue)
        XCTAssertEqual(queue.items.first?.errorMessage, FileTransferError.localStorage.localizedDescription)
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testOverlappingSessionChangesCannotRestoreStaleDeviceAfterAwait() async throws {
        let root = try fixture(), transport = SpecimenTransferTransport(.gatedCommit), queue = coordinator(root, transport)
        await connect(queue)
        queue.enqueue([try file(root)])
        for _ in 0..<100 {
            if await transport.commitStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstTransition = Task { await self.connect(queue, "stale-device") }
        try await Task.sleep(for: .milliseconds(10))
        let latestTransition = Task { await self.connect(queue, "intended-device") }
        try await Task.sleep(for: .milliseconds(10))
        await transport.releaseCommit()
        await firstTransition.value; await latestTransition.value
        await transport.setBehavior(.success)
        queue.enqueue([try file(root, "next.txt")])
        try await settle(queue)
        let calls = await transport.calls
        XCTAssertTrue(calls.contains("prepare:intended-device"))
        XCTAssertFalse(calls.contains("prepare:stale-device"))
    }

    func testRemoteShellQuotingTreatsNamesAsOneLiteralArgument() {
        XCTAssertEqual(ADBFileTransferTransport.quote("a'b $(touch /bad)\n🌲"), "'a'\\''b $(touch /bad)\n🌲'")
    }

    func testUploadRateCanChangeWithoutReplacingActiveSessionOrQueue() throws {
        let root = try fixture(), transport = SpecimenTransferTransport()
        let queue = coordinator(root, transport)
        XCTAssertEqual(queue.uploadRateLimit, 500_000)
        queue.setUploadRateLimit(bytesPerSecond: 125_000)
        XCTAssertEqual(queue.uploadRateLimit, 125_000)
        queue.setUploadRateLimit(bytesPerSecond: nil)
        XCTAssertNil(queue.uploadRateLimit)
        queue.setUploadRateLimit(bytesPerSecond: 0)
        XCTAssertEqual(queue.uploadRateLimit, 1)
    }
}

private struct TransferHelperFixture: Sendable {
    let root: URL
    let downloads: URL
    let executable: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NearbyTransferHelper-" + UUID().uuidString)
        downloads = root.appendingPathComponent("Downloads")
        executable = root.appendingPathComponent("helper")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/nearby-transfer.c")
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-DNEARBY_TRANSFER_HOST_TEST", source.path, "-o", executable.path]
        try compiler.run(); compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw FileTransferError.helperUnavailable }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func run(_ arguments: [String]) throws -> CommandOutput {
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment; environment["NEARBY_TEST_DOWNLOADS"] = downloads.path
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe(); process.standardOutput = stdout; process.standardError = stderr
        try process.run(); process.waitUntilExit()
        return CommandOutput(stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                             stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), status: process.terminationStatus)
    }
    func stage(_ token: String) -> URL { downloads.appendingPathComponent(".nearby-transfer-" + token) }
    func prepare(_ data: Data) throws -> String {
        let token = UUID().uuidString.lowercased()
        let response = try run(["prepare", token, String(data.count)])
        guard response.status == 0 else { throw FileTransferError.protocolFailure }
        try data.write(to: stage(token).appendingPathComponent("payload.partial"))
        return token
    }
}

@MainActor final class TransferHelperTests: XCTestCase {
    func testDuplicateNamesDirectoriesAndSymlinksNeverOverwriteAnything() throws {
        let helper = try TransferHelperFixture(); defer { helper.remove() }
        let sentinel = Data("unrelated existing file".utf8)
        let name = "Report 你好 🌲.txt"
        try sentinel.write(to: helper.downloads.appendingPathComponent(name))
        try FileManager.default.createDirectory(at: helper.downloads.appendingPathComponent("Report 你好 🌲 (2).txt"), withIntermediateDirectories: false)
        let link = helper.downloads.appendingPathComponent("Report 你好 🌲 (3).txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper.downloads.appendingPathComponent(name))
        let content = Data("Nearby sample".utf8), token = try helper.prepare(content)
        let result = try helper.run(["commit", token, name, String(content.count)])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "OK\tReport 你好 🌲 (4).txt")
        XCTAssertEqual(try Data(contentsOf: helper.downloads.appendingPathComponent(name)), sentinel)
        XCTAssertEqual(try Data(contentsOf: helper.downloads.appendingPathComponent("Report 你好 🌲 (4).txt")), content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.stage(token).appendingPathComponent("payload.partial").path))
        XCTAssertEqual(try helper.run(["cleanup", token]).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.stage(token).path))
    }

    func testParallelCommitsWithSameNameKeepEveryFileAndExistingContent() async throws {
        let helper = try TransferHelperFixture(); defer { helper.remove() }
        let existing = Data("existing".utf8)
        try existing.write(to: helper.downloads.appendingPathComponent("same.txt"))
        let specimens = try (0..<12).map { index -> (String, Data) in
            let data = Data("sample \(index)".utf8)
            return (try helper.prepare(data), data)
        }
        let outputs = try await withThrowingTaskGroup(of: (String, Data).self) { group in
            for (token, data) in specimens {
                group.addTask {
                    let result = try helper.run(["commit", token, "same.txt", String(data.count)])
                    guard result.status == 0 else { throw FileTransferError.protocolFailure }
                    return (String(result.stdout.dropFirst(3)), data)
                }
            }
            var results: [(String, Data)] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(Set(outputs.map(\.0)).count, specimens.count)
        XCTAssertEqual(try Data(contentsOf: helper.downloads.appendingPathComponent("same.txt")), existing)
        for (name, data) in outputs { XCTAssertEqual(try Data(contentsOf: helper.downloads.appendingPathComponent(name)), data) }
    }

    func testNamesWithSpacesNewlinesAndShellSyntaxArePreservedAsData() throws {
        let helper = try TransferHelperFixture(); defer { helper.remove() }
        let content = Data([1, 2, 3]), token = try helper.prepare(content)
        let name = "  a'b $HOME `name`\n你好 .txt  "
        let output = try helper.run(["commit", token, name, "3"])
        XCTAssertEqual(output.status, 0); XCTAssertEqual(output.stdout, "OK\t" + name)
        XCTAssertEqual(try Data(contentsOf: helper.downloads.appendingPathComponent(name)), content)
    }

    func testCleanupRefusesUnownedFoldersAndSymlinksAndPreservesForeignFiles() throws {
        let helper = try TransferHelperFixture(); defer { helper.remove() }
        let token = UUID().uuidString.lowercased(), unowned = helper.stage(token)
        try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: false)
        let unrelated = Data("keep me".utf8)
        try unrelated.write(to: unowned.appendingPathComponent("payload.partial"))
        XCTAssertEqual(try helper.run(["cleanup", token]).status, 26)
        XCTAssertEqual(try Data(contentsOf: unowned.appendingPathComponent("payload.partial")), unrelated)
        let own = try helper.prepare(Data([1]))
        try unrelated.write(to: helper.stage(own).appendingPathComponent("foreign.txt"))
        XCTAssertEqual(try helper.run(["cleanup", own]).status, 0)
        XCTAssertEqual(try Data(contentsOf: helper.stage(own).appendingPathComponent("foreign.txt")), unrelated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.stage(own).appendingPathComponent("payload.partial").path))
        let symlinkToken = try helper.prepare(Data([2]))
        let target = helper.root.appendingPathComponent("unrelated.txt")
        try unrelated.write(to: target)
        let partial = helper.stage(symlinkToken).appendingPathComponent("payload.partial")
        try FileManager.default.removeItem(at: partial)
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: target)
        XCTAssertEqual(try helper.run(["cleanup", symlinkToken]).status, 26)
        XCTAssertEqual(try Data(contentsOf: target), unrelated)
        XCTAssertEqual(try helper.run(["commit", symlinkToken, "never.txt", String(unrelated.count)]).status, 26)
    }

    func testWrongSizeAndStoragePreflightDoNotCreateFinalFiles() throws {
        let helper = try TransferHelperFixture(); defer { helper.remove() }
        let token = try helper.prepare(Data([1, 2]))
        XCTAssertEqual(try helper.run(["commit", token, "never.txt", "3"]).status, 27)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.downloads.appendingPathComponent("never.txt").path))
        let storageToken = UUID().uuidString.lowercased()
        XCTAssertEqual(try helper.run(["prepare", storageToken, String(Int64.max)]).status, 21)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.stage(storageToken).path))
        XCTAssertEqual(try helper.run(["commit", token, "../escape", "2"]).status, 24)
    }

    func testDuplicateSuffixTruncatesAtUnicodeBoundaryWithin255Bytes() throws {
        let helper = try TransferHelperFixture(); defer { helper.remove() }
        let name = String(repeating: "🌲", count: 62) + ".txt"
        let initial = Data([0]), content = Data([1]), token = try helper.prepare(content)
        try initial.write(to: helper.downloads.appendingPathComponent(name))
        let result = try helper.run(["commit", token, name, "1"])
        XCTAssertEqual(result.status, 0)
        let final = String(result.stdout.dropFirst(3))
        XCTAssertLessThanOrEqual(final.utf8.count, 255)
        XCTAssertTrue(final.hasSuffix(" (2).txt")); XCTAssertFalse(final.contains("�"))
        XCTAssertEqual(try Data(contentsOf: helper.downloads.appendingPathComponent(final)), content)
    }
}

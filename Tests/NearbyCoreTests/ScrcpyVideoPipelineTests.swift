import XCTest
@testable import NearbyCore

final class ScrcpyVideoPipelineTests: XCTestCase {
    func testNativeDecodeCompletesOutputBeforeNextSubmissionAndPreservesLocalTiming() throws {
        final class FrameCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var frames: [DecodedVideoFrame] = []
            func record(_ frame: DecodedVideoFrame) { lock.lock(); frames.append(frame); lock.unlock() }
            var values: [DecodedVideoFrame] { lock.lock(); defer { lock.unlock() }; return frames }
        }
        let data = Data(base64Encoded: "AAAAAWdCwAraENsBEAAAAwAQAAADACjxImoAAAABaM4PyAAAAWWIhDoRigACMXHAAEPKOAAIBcnJyddddddddddddddddddddeA=")!
        let collector = FrameCollector()
        let decoder = VideoDecoder(onDecodedFrame: { collector.record($0) })
        defer { decoder.invalidate() }
        let receivedAt = scrcpyMonotonicTime() - 0.03
        for index in 0..<3 {
            try decoder.decode(data, header: header(pts: UInt64(index) * 16_667), receivedAt: receivedAt)
            XCTAssertEqual(collector.values.count, index + 1, "No hardware decode may remain pending when the next access unit starts")
        }
        let decoded = try XCTUnwrap(collector.values.first)
        XCTAssertEqual(decoded.receivedAt, receivedAt)
        XCTAssertGreaterThanOrEqual(decoded.submittedAt, receivedAt)
        XCTAssertLessThanOrEqual(decoded.submittedAt, scrcpyMonotonicTime())
        let prepared = try XCTUnwrap(PreparedVideoFrame(decoded))
        XCTAssertEqual(prepared.size, CGSize(width: 64, height: 96))
    }

    func testNewestDecodedFrameReplacesPendingFrameWithOneScheduledDrain() {
        let mailbox = LatestFrameMailbox<Int>()
        XCTAssertEqual(mailbox.offer(0), .init(accepted: true, replaced: false, shouldSchedule: true))
        for frame in 1...1_000 {
            XCTAssertEqual(mailbox.offer(frame), .init(accepted: true, replaced: true, shouldSchedule: false))
            XCTAssertEqual(mailbox.pendingCount, 1)
        }
        XCTAssertEqual(mailbox.takeForDrain(), 1_000)
        XCTAssertEqual(mailbox.pendingCount, 0)
        XCTAssertFalse(mailbox.finishDrain())
    }

    func testFrameArrivingDuringDrainGetsAnotherTurnWithoutLostWakeup() {
        let mailbox = LatestFrameMailbox<Int>()
        XCTAssertTrue(mailbox.offer(1).shouldSchedule)
        XCTAssertEqual(mailbox.takeForDrain(), 1)
        XCTAssertFalse(mailbox.offer(2).shouldSchedule, "The existing drain owns the wakeup until it finishes")
        XCTAssertTrue(mailbox.finishDrain(), "A new executor turn must be scheduled for the newer frame")
        XCTAssertEqual(mailbox.takeForDrain(), 2)
        XCTAssertFalse(mailbox.finishDrain())
        XCTAssertTrue(mailbox.offer(3).shouldSchedule, "A producer following completion must schedule its own drain")
    }

    func testClosedGenerationReleasesPendingFrameAndRejectsLateOutput() {
        let mailbox = LatestFrameMailbox<Int>()
        _ = mailbox.offer(1)
        mailbox.close()
        XCTAssertEqual(mailbox.pendingCount, 0)
        XCTAssertNil(mailbox.takeForDrain())
        XCTAssertFalse(mailbox.finishDrain())
        XCTAssertEqual(mailbox.offer(2), .init(accepted: false, replaced: false, shouldSchedule: false))
    }

    func testConcurrentProducersKeepOnePendingFrameAndScheduleOneDrain() {
        final class Schedules: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let mailbox = LatestFrameMailbox<Int>()
        let schedules = Schedules()
        DispatchQueue.concurrentPerform(iterations: 1_000) { value in
            if mailbox.offer(value).shouldSchedule { schedules.increment() }
        }
        XCTAssertEqual(schedules.value, 1)
        XCTAssertEqual(mailbox.pendingCount, 1)
        XCTAssertNotNil(mailbox.takeForDrain())
        XCTAssertFalse(mailbox.finishDrain())
    }

    func testTelemetryUsesRelativePTSAndResetsIntervalCounters() throws {
        let counters = ScrcpyPerformanceCounters(now: 1_000)
        // Android's timestamp origin intentionally differs from the Mac's.
        counters.received(bytes: 100, header: try header(pts: 9_000_000_000), at: 1_000)
        counters.received(bytes: 200, header: try header(pts: 9_001_000_000), at: 1_001.15)
        counters.decoded(); counters.decoded(); counters.dropped()
        counters.presented(receivedAt: 1_001.15, at: 1_001.20, flushed: true)
        let sample = counters.takeSample(at: 1_002)
        XCTAssertEqual(sample.encodedBytes, 300)
        XCTAssertEqual(sample.receivedFrames, 2)
        XCTAssertEqual(sample.decodedFrames, 2)
        XCTAssertEqual(sample.presentedFrames, 1)
        XCTAssertEqual(sample.droppedFrames, 1)
        XCTAssertEqual(sample.rendererFlushes, 1)
        XCTAssertEqual(sample.interval, 2)
        XCTAssertEqual(sample.streamBacklogGrowth, 0.15, accuracy: 0.0001)
        XCTAssertEqual(sample.maximumPresentationDelay, 0.05, accuracy: 0.0001)
        let idle = counters.takeSample(at: 1_004)
        XCTAssertEqual(idle.encodedBytes, 0)
        XCTAssertEqual(idle.receivedFrames, 0)
        XCTAssertEqual(idle.decodedFrames, 0)
        XCTAssertEqual(idle.presentedFrames, 0)
        XCTAssertEqual(idle.droppedFrames, 0)
        XCTAssertEqual(idle.rendererFlushes, 0)
        XCTAssertEqual(idle.maximumPresentationDelay, 0)
        XCTAssertEqual(idle.streamBacklogGrowth, 0)
    }

    func testStaticScreenIdleAndTimestampResetDoNotReportNetworkBacklog() throws {
        let counters = ScrcpyPerformanceCounters(now: 100)
        counters.received(bytes: 100, header: try header(pts: 10_000_000), at: 100)
        _ = counters.takeSample(at: 102)
        // Five minutes without a changed screen is five minutes in both clocks.
        counters.received(bytes: 100, header: try header(pts: 310_000_000), at: 400)
        XCTAssertEqual(counters.takeSample(at: 402).streamBacklogGrowth, 0, accuracy: 0.0001)
        counters.received(bytes: 100, header: try header(pts: 0), at: 403)
        XCTAssertEqual(counters.takeSample(at: 404).streamBacklogGrowth, 0)
    }

    func testConfigurationPacketsCountBandwidthWithoutInventingFramesOrPTS() throws {
        let counters = ScrcpyPerformanceCounters(now: 100)
        counters.received(bytes: 80, header: try header(pts: 0, configuration: true), at: 100)
        let sample = counters.takeSample(at: 102)
        XCTAssertEqual(sample.encodedBytes, 80)
        XCTAssertEqual(sample.receivedFrames, 0)
        XCTAssertEqual(sample.streamBacklogGrowth, 0)
    }

    private func header(pts: UInt64, configuration: Bool = false) throws -> ScrcpyFrameHeader {
        var data = Data()
        data.appendBE(pts | (configuration ? UInt64(1) << 63 : 0)); data.appendBE(UInt32(1))
        return try ScrcpyFrameHeader(data)
    }
}

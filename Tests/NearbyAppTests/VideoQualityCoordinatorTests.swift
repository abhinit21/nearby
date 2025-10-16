import XCTest
import NearbyCore
@testable import Nearby

@MainActor
private final class QualityApplyProbe {
    struct Request {
        let profile: StreamQualityProfile
        let generation: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private(set) var requests: [Request] = []
    private var completed = Set<Int>()

    func apply(_ profile: StreamQualityProfile, generation: UUID) async -> Bool {
        await withCheckedContinuation { requests.append(Request(profile: profile, generation: generation, continuation: $0)) }
    }

    func finish(_ index: Int, success: Bool = true) {
        guard completed.insert(index).inserted else { return }
        requests[index].continuation.resume(returning: success)
    }
}

@MainActor
final class VideoQualityCoordinatorTests: XCTestCase {
    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    func testPreferenceDuringInitialStartupAppliesAfterFirstFrame() async {
        let coordinator = VideoQualityCoordinator(clock: { 0 })
        let probe = QualityApplyProbe(), generation = UUID()
        coordinator.applyProfile = { await probe.apply($0, generation: $1) }
        coordinator.open(generation: generation, ceiling: .balanced, automatic: true)
        coordinator.configure(ceiling: .efficient, automatic: false)
        await settle()
        XCTAssertTrue(probe.requests.isEmpty)
        XCTAssertEqual(coordinator.profileForStart, .efficient)
        coordinator.streamStarted(profile: .balanced)
        await settle()
        XCTAssertEqual(probe.requests.map(\.profile), [.efficient])
        probe.finish(0)
        await settle()
        XCTAssertEqual(coordinator.currentProfile, .efficient)
        XCTAssertFalse(coordinator.isApplying)
        coordinator.close()
    }

    func testChangesDuringRestartCoalesceToLatestPreference() async {
        let coordinator = VideoQualityCoordinator(clock: { 0 })
        let probe = QualityApplyProbe(), generation = UUID()
        coordinator.applyProfile = { await probe.apply($0, generation: $1) }
        coordinator.open(generation: generation, ceiling: .balanced, automatic: false)
        coordinator.streamStarted(profile: .balanced)
        coordinator.configure(ceiling: .efficient, automatic: false)
        await settle()
        coordinator.configure(ceiling: .high, automatic: false)
        coordinator.configure(ceiling: .constrained, automatic: false)
        XCTAssertEqual(probe.requests.count, 1)
        probe.finish(0)
        await settle()
        XCTAssertEqual(probe.requests.map(\.profile), [.efficient, .constrained])
        probe.finish(1)
        await settle()
        XCTAssertEqual(coordinator.currentProfile, .constrained)
        XCTAssertFalse(coordinator.isApplying)
        coordinator.close()
    }

    func testFirstFrameAndPreferenceBeforeApplyReturnsDoNotRestartSameProfile() async {
        let coordinator = VideoQualityCoordinator(clock: { 0 })
        let probe = QualityApplyProbe(), generation = UUID()
        coordinator.applyProfile = { await probe.apply($0, generation: $1) }
        coordinator.open(generation: generation, ceiling: .balanced, automatic: false)
        coordinator.streamStarted(profile: .balanced)
        coordinator.configure(ceiling: .efficient, automatic: false)
        await settle()
        coordinator.streamStarted(profile: .efficient)
        coordinator.configure(ceiling: .efficient, automatic: false)
        probe.finish(0)
        await settle()
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertFalse(coordinator.isApplying)
        coordinator.close()
    }

    func testClosingRevokesLateCompletionAndCannotChangeReplacementSession() async {
        let coordinator = VideoQualityCoordinator(clock: { 0 })
        let probe = QualityApplyProbe(), old = UUID(), replacement = UUID()
        coordinator.applyProfile = { await probe.apply($0, generation: $1) }
        coordinator.open(generation: old, ceiling: .balanced, automatic: false)
        coordinator.streamStarted(profile: .balanced)
        coordinator.configure(ceiling: .efficient, automatic: false)
        await settle()
        coordinator.close()
        coordinator.open(generation: replacement, ceiling: .high, automatic: true)
        coordinator.streamStarted(profile: .high)
        probe.finish(0)
        await settle()
        XCTAssertEqual(coordinator.currentProfile, .high)
        XCTAssertFalse(coordinator.isApplying)
        XCTAssertEqual(probe.requests.count, 1)
        coordinator.close()
    }

    func testInterruptionRetainsTargetForRecoveryAndRejectsOldRestart() async {
        let coordinator = VideoQualityCoordinator(clock: { 0 })
        let probe = QualityApplyProbe(), generation = UUID()
        coordinator.applyProfile = { await probe.apply($0, generation: $1) }
        coordinator.open(generation: generation, ceiling: .balanced, automatic: false)
        coordinator.streamStarted(profile: .balanced)
        coordinator.configure(ceiling: .efficient, automatic: false)
        await settle()
        coordinator.suspend()
        XCTAssertEqual(coordinator.profileForStart, .efficient)
        coordinator.streamStarted(profile: .efficient)
        probe.finish(0)
        await settle()
        XCTAssertEqual(coordinator.currentProfile, .efficient)
        XCTAssertFalse(coordinator.isApplying)
        XCTAssertEqual(probe.requests.count, 1)
        coordinator.close()
    }

    func testStaleSamplesAndManualModeCannotChangeQuality() async {
        var now = 0.0
        let coordinator = VideoQualityCoordinator(clock: { now })
        let probe = QualityApplyProbe(), generation = UUID()
        coordinator.applyProfile = { await probe.apply($0, generation: $1) }
        coordinator.open(generation: generation, ceiling: .balanced, automatic: true)
        coordinator.streamStarted(profile: .balanced)
        let pressure = StreamPerformanceSample(receivedFrames: 120, presentedFrames: 60,
                                              droppedFrames: 60, maximumPresentationDelay: 0.5)
        for value in stride(from: 2.0, through: 24.0, by: 2.0) {
            now = value
            coordinator.receive(pressure, generation: UUID())
        }
        XCTAssertNil(coordinator.latestSample)
        coordinator.configure(ceiling: .balanced, automatic: false)
        for value in stride(from: 26.0, through: 50.0, by: 2.0) {
            now = value
            coordinator.receive(pressure, generation: generation)
        }
        await settle()
        XCTAssertTrue(probe.requests.isEmpty)
        XCTAssertEqual(coordinator.currentProfile, .balanced)
        coordinator.close()
    }

    func testSustainedPressureSchedulesOneRestartAndPausesEvaluation() async {
        var now = 0.0
        let coordinator = VideoQualityCoordinator(clock: { now })
        let probe = QualityApplyProbe(), generation = UUID()
        coordinator.applyProfile = { await probe.apply($0, generation: $1) }
        coordinator.open(generation: generation, ceiling: .balanced, automatic: true)
        coordinator.streamStarted(profile: .balanced)
        let pressure = StreamPerformanceSample(receivedFrames: 120, presentedFrames: 60,
                                              droppedFrames: 60, maximumPresentationDelay: 0.5)
        for value in stride(from: 2.0, through: 60.0, by: 2.0) {
            now = value
            coordinator.receive(pressure, generation: generation)
        }
        await settle()
        XCTAssertEqual(probe.requests.map(\.profile), [.efficient])
        XCTAssertEqual(coordinator.profileForStart, .efficient)
        probe.finish(0)
        await settle()
        XCTAssertEqual(coordinator.currentProfile, .efficient)
        coordinator.close()
    }

    func testRaisingAutomaticCeilingDoesNotImmediatelyUpgrade() async {
        let coordinator = VideoQualityCoordinator(clock: { 0 })
        let probe = QualityApplyProbe(), generation = UUID()
        coordinator.applyProfile = { await probe.apply($0, generation: $1) }
        coordinator.open(generation: generation, ceiling: .efficient, automatic: true)
        coordinator.streamStarted(profile: .efficient)
        coordinator.configure(ceiling: .high, automatic: true)
        await settle()
        XCTAssertEqual(coordinator.profileForStart, .efficient)
        XCTAssertTrue(probe.requests.isEmpty)
        coordinator.close()
    }

    func testFailedApplyDoesNotCreateItsOwnRetryLoop() async {
        let coordinator = VideoQualityCoordinator(clock: { 0 })
        let probe = QualityApplyProbe(), generation = UUID()
        coordinator.applyProfile = { await probe.apply($0, generation: $1) }
        coordinator.open(generation: generation, ceiling: .balanced, automatic: false)
        coordinator.streamStarted(profile: .balanced)
        coordinator.configure(ceiling: .efficient, automatic: false)
        await settle()
        probe.finish(0, success: false)
        await settle()
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertFalse(coordinator.isApplying)
        XCTAssertEqual(coordinator.profileForStart, .efficient)
        coordinator.close()
    }
}

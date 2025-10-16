import XCTest
@testable import NearbyCore

final class AdaptiveQualityTests: XCTestCase {
    private let healthy = StreamPerformanceSample(encodedBytes: 1_000_000, receivedFrames: 60,
                                                  decodedFrames: 60, presentedFrames: 60,
                                                  maximumPresentationDelay: 0.04)
    private let delayed = StreamPerformanceSample(receivedFrames: 60, decodedFrames: 60,
                                                  presentedFrames: 60, maximumPresentationDelay: 0.40)

    func testProfilesHaveOrderedLimitsAndThirtyFPSFallbacks() {
        XCTAssertLessThan(StreamQualityProfile.constrained, .efficient)
        XCTAssertLessThan(StreamQualityProfile.efficient, .balanced)
        XCTAssertLessThan(StreamQualityProfile.balanced, .high)
        XCTAssertEqual(StreamQualityProfile.allCases.map(\.maxSize), [1024, 1280, 1920, 2560])
        XCTAssertEqual(StreamQualityProfile.allCases.map(\.bitRate), [2_000_000, 4_000_000, 8_000_000, 12_000_000])
        XCTAssertEqual(StreamQualityProfile.allCases.map(\.maxFPS), [30, 30, 60, 60])
        let capped = AdaptiveQualityController(ceiling: .efficient, initialProfile: .high, now: 0)
        XCTAssertEqual(capped.currentProfile, .efficient)
    }

    func testPressureRequiresWarmupConsecutiveWindowsAndDwell() {
        var controller = AdaptiveQualityController(ceiling: .high, now: 0)
        for time in stride(from: 2.0, through: 8, by: 2) {
            XCTAssertNil(controller.evaluate(sample: delayed, at: time))
        }
        XCTAssertNil(controller.evaluate(sample: delayed, at: 10))
        XCTAssertNil(controller.evaluate(sample: healthy, at: 12), "Healthy window breaks pressure streak")
        XCTAssertNil(controller.evaluate(sample: delayed, at: 14))
        XCTAssertEqual(controller.evaluate(sample: delayed, at: 16),
                       AdaptiveQualityDecision(previousProfile: .high, profile: .balanced, reason: .sustainedPressure))
        for time in stride(from: 18.0, through: 30, by: 2) {
            XCTAssertNil(controller.evaluate(sample: delayed, at: time))
        }
        XCTAssertEqual(controller.evaluate(sample: delayed, at: 32)?.profile, .efficient)
    }

    func testBacklogDropsAndRendererPressureCanEachReduceQuality() {
        let samples = [
            StreamPerformanceSample(receivedFrames: 60, presentedFrames: 60, streamBacklogGrowth: 0.20),
            StreamPerformanceSample(receivedFrames: 60, presentedFrames: 40, droppedFrames: 20),
            StreamPerformanceSample(receivedFrames: 60, presentedFrames: 60, rendererFlushes: 1)
        ]
        for sample in samples {
            var controller = AdaptiveQualityController(ceiling: .balanced, now: 0)
            for time in stride(from: 2.0, through: 14, by: 2) {
                XCTAssertNil(controller.evaluate(sample: sample, at: time))
            }
            XCTAssertEqual(controller.evaluate(sample: sample, at: 16)?.profile, .efficient)
        }
    }

    func testLowContentDemandAndIdleScreensNeitherDegradeNorRecover() {
        let samples = [StreamPerformanceSample(),
                       StreamPerformanceSample(encodedBytes: 20_000, receivedFrames: 4,
                                               decodedFrames: 4, presentedFrames: 4),
                       StreamPerformanceSample(encodedBytes: 4_000_000)]
        for sample in samples {
            var controller = AdaptiveQualityController(ceiling: .high, initialProfile: .efficient, now: 0)
            for time in stride(from: 2.0, through: 120, by: 2) {
                XCTAssertNil(controller.evaluate(sample: sample, at: time))
            }
            XCTAssertEqual(controller.currentProfile, .efficient)
        }
    }

    func testRecoveryRequiresThirtySecondsOfConsecutiveHealthyActiveVideoAndStopsAtCeiling() {
        var controller = AdaptiveQualityController(ceiling: .balanced, initialProfile: .efficient, now: 0)
        for time in stride(from: 2.0, through: 36, by: 2) {
            XCTAssertNil(controller.evaluate(sample: healthy, at: time))
        }
        XCTAssertEqual(controller.evaluate(sample: healthy, at: 38),
                       AdaptiveQualityDecision(previousProfile: .efficient, profile: .balanced,
                                               reason: .sustainedHealthyVideo))
        for time in stride(from: 40.0, through: 100, by: 2) {
            XCTAssertNil(controller.evaluate(sample: healthy, at: time))
        }
        XCTAssertEqual(controller.currentProfile, .balanced)
    }

    func testStaticOrMarginalWindowInterruptsRecoveryEvidence() {
        for interruption in [StreamPerformanceSample(),
                             StreamPerformanceSample(receivedFrames: 60, presentedFrames: 60,
                                                     maximumPresentationDelay: 0.20)] {
            var controller = AdaptiveQualityController(ceiling: .balanced, initialProfile: .efficient, now: 0)
            for time in stride(from: 2.0, through: 30, by: 2) {
                XCTAssertNil(controller.evaluate(sample: healthy, at: time))
            }
            XCTAssertNil(controller.evaluate(sample: interruption, at: 32))
            for time in stride(from: 34.0, through: 60, by: 2) {
                XCTAssertNil(controller.evaluate(sample: healthy, at: time))
            }
            XCTAssertEqual(controller.evaluate(sample: healthy, at: 62)?.profile, .balanced)
        }
    }

    func testMailboxDropsOrUncountedDecodeLossPreventFalseRecovery() {
        let samples = [
            StreamPerformanceSample(receivedFrames: 120, decodedFrames: 120,
                                    presentedFrames: 90, droppedFrames: 30),
            StreamPerformanceSample(receivedFrames: 120, decodedFrames: 120, presentedFrames: 60),
            StreamPerformanceSample(receivedFrames: 60, decodedFrames: 120, presentedFrames: 60)
        ]
        for sample in samples {
            var controller = AdaptiveQualityController(ceiling: .high, initialProfile: .constrained, now: 0)
            for time in stride(from: 2.0, through: 120, by: 2) {
                XCTAssertNil(controller.evaluate(sample: sample, at: time))
            }
            XCTAssertEqual(controller.currentProfile, .constrained)
        }
    }

    func testFailedRecoveryProbesBackOffAndHistorySurvivesRestart() {
        var controller = AdaptiveQualityController(ceiling: .balanced, initialProfile: .efficient, now: 0)
        var time = 0.0
        for requiredDuration in [30.0, 60, 120, 240, 240] {
            XCTAssertEqual(controller.requiredHealthyDuration, requiredDuration)
            let recoveryAt = time + 8 + requiredDuration
            for sampleTime in stride(from: time + 2, to: recoveryAt, by: 2) {
                XCTAssertNil(controller.evaluate(sample: healthy, at: sampleTime))
            }
            XCTAssertEqual(controller.evaluate(sample: healthy, at: recoveryAt)?.profile, .balanced)
            controller.resetMetrics(at: recoveryAt)
            for sampleTime in stride(from: recoveryAt + 2, through: recoveryAt + 14, by: 2) {
                XCTAssertNil(controller.evaluate(sample: delayed, at: sampleTime))
            }
            time = recoveryAt + 16
            XCTAssertEqual(controller.evaluate(sample: delayed, at: time)?.profile, .efficient)
            controller.resetMetrics(at: time)
            XCTAssertEqual(controller.currentProfile, .efficient)
        }
        XCTAssertEqual(controller.requiredHealthyDuration, 240)
        XCTAssertEqual(AdaptiveQualityController(ceiling: .balanced, now: time).requiredHealthyDuration, 30,
                       "A new device/controller does not inherit the previous path's failed probes")
    }

    func testPressureAfterAStableTrialDoesNotIncreaseBackoff() {
        var controller = AdaptiveQualityController(ceiling: .balanced, initialProfile: .efficient, now: 0)
        for time in stride(from: 2.0, through: 36, by: 2) {
            XCTAssertNil(controller.evaluate(sample: healthy, at: time))
        }
        XCTAssertEqual(controller.evaluate(sample: healthy, at: 38)?.profile, .balanced)
        for time in stride(from: 40.0, through: 70, by: 2) {
            XCTAssertNil(controller.evaluate(sample: healthy, at: time))
        }
        XCTAssertNil(controller.evaluate(sample: delayed, at: 72))
        XCTAssertEqual(controller.evaluate(sample: delayed, at: 74)?.profile, .efficient)
        XCTAssertEqual(controller.requiredHealthyDuration, 30)
    }

    func testUserCeilingChangeIsNotAFailedRecoveryProbe() {
        var controller = AdaptiveQualityController(ceiling: .balanced, initialProfile: .efficient, now: 0)
        for time in stride(from: 2.0, through: 36, by: 2) {
            XCTAssertNil(controller.evaluate(sample: healthy, at: time))
        }
        XCTAssertEqual(controller.evaluate(sample: healthy, at: 38)?.profile, .balanced)
        XCTAssertEqual(controller.setCeiling(.efficient, at: 40)?.reason, .userCeiling)
        XCTAssertEqual(controller.requiredHealthyDuration, 30)
    }

    func testRestartDiscardsEvidencePreservesChoiceAndDoesNotResetDwell() {
        var controller = AdaptiveQualityController(ceiling: .high, now: 0)
        for time in stride(from: 2.0, through: 14, by: 2) {
            XCTAssertNil(controller.evaluate(sample: delayed, at: time))
        }
        XCTAssertEqual(controller.evaluate(sample: delayed, at: 16)?.profile, .balanced)
        controller.resetMetrics(at: 20)
        XCTAssertEqual(controller.currentProfile, .balanced)
        for time in stride(from: 22.0, through: 30, by: 2) {
            XCTAssertNil(controller.evaluate(sample: delayed, at: time))
        }
        XCTAssertEqual(controller.evaluate(sample: delayed, at: 32)?.profile, .efficient,
                       "Dwell is measured from the quality change, not a later transport restart")
    }

    func testUserCeilingImmediatelyCapsAndLaterRaisingDoesNotEraseAdaptiveChoice() {
        var controller = AdaptiveQualityController(ceiling: .high, now: 0)
        XCTAssertEqual(controller.setCeiling(.efficient, at: 1),
                       AdaptiveQualityDecision(previousProfile: .high, profile: .efficient, reason: .userCeiling))
        XCTAssertNil(controller.setCeiling(.high, at: 2))
        XCTAssertEqual(controller.ceiling, .high)
        XCTAssertEqual(controller.currentProfile, .efficient)
        for time in stride(from: 4.0, through: 38, by: 2) {
            XCTAssertNil(controller.evaluate(sample: healthy, at: time))
        }
        XCTAssertEqual(controller.evaluate(sample: healthy, at: 40)?.profile, .balanced)
    }

    func testInvalidOutOfOrderAndSuspendedWindowsCannotCreateDecisions() {
        var controller = AdaptiveQualityController(ceiling: .balanced, initialProfile: .efficient, now: 0)
        for time in stride(from: 2.0, through: 30, by: 2) {
            XCTAssertNil(controller.evaluate(sample: healthy, at: time))
        }
        XCTAssertNil(controller.evaluate(sample: delayed, at: 29))
        XCTAssertNil(controller.evaluate(sample: healthy, at: 100), "A gap is not continuous healthy video")
        XCTAssertNil(controller.evaluate(sample: StreamPerformanceSample(interval: .nan), at: 102))
        for time in stride(from: 104.0, through: 130, by: 2) {
            XCTAssertNil(controller.evaluate(sample: healthy, at: time))
        }
        XCTAssertEqual(controller.evaluate(sample: healthy, at: 132)?.profile, .balanced)
    }
}

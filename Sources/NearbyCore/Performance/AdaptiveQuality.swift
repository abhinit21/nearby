import Foundation

/// Ordered by resource demand so a user preference can act as an upper bound.
/// These are encoder limits, not measurements of available network bandwidth.
public enum StreamQualityProfile: Int, CaseIterable, Comparable, Equatable, Sendable {
    case constrained = 0
    case efficient
    case balanced
    case high

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var maxSize: Int {
        switch self {
        case .high: 2560
        case .balanced: 1920
        case .efficient: 1280
        case .constrained: 1024
        }
    }

    public var bitRate: Int {
        switch self {
        case .high: 12_000_000
        case .balanced: 8_000_000
        case .efficient: 4_000_000
        case .constrained: 2_000_000
        }
    }

    public var maxFPS: Int { self >= .balanced ? 60 : 30 }
}

/// One completed observation window, normally two seconds. Frame counts refer
/// to actual video frames, excluding codec configuration packets. Presentation
/// delay measures local packet arrival to display submission, not end-to-end
/// latency. Backlog growth measures increasing arrival-minus-media-time offset
/// within the window; a constant clock offset or a static screen is not backlog.
public struct StreamPerformanceSample: Equatable, Sendable {
    public var encodedBytes: Int
    public var receivedFrames: Int
    public var decodedFrames: Int
    public var presentedFrames: Int
    public var droppedFrames: Int
    public var maximumPresentationDelay: TimeInterval
    public var streamBacklogGrowth: TimeInterval
    public var rendererFlushes: Int
    public var interval: TimeInterval

    public init(encodedBytes: Int = 0, receivedFrames: Int = 0, decodedFrames: Int = 0,
                presentedFrames: Int = 0, droppedFrames: Int = 0,
                maximumPresentationDelay: TimeInterval = 0, streamBacklogGrowth: TimeInterval = 0,
                rendererFlushes: Int = 0, interval: TimeInterval = 2) {
        self.encodedBytes = encodedBytes
        self.receivedFrames = receivedFrames
        self.decodedFrames = decodedFrames
        self.presentedFrames = presentedFrames
        self.droppedFrames = droppedFrames
        self.maximumPresentationDelay = maximumPresentationDelay
        self.streamBacklogGrowth = streamBacklogGrowth
        self.rendererFlushes = rendererFlushes
        self.interval = interval
    }
}

public struct AdaptiveQualityDecision: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case sustainedPressure
        /// A cautious trial of the next level, not a bandwidth estimate.
        case sustainedHealthyVideo
        case userCeiling
    }

    public let previousProfile: StreamQualityProfile
    public let profile: StreamQualityProfile
    public let reason: Reason

    public init(previousProfile: StreamQualityProfile, profile: StreamQualityProfile, reason: Reason) {
        self.previousProfile = previousProfile
        self.profile = profile
        self.reason = reason
    }
}

/// Pure, monotonic-time adaptation policy. A decision commits its next profile;
/// the caller applies it with a controlled stream restart, pauses observation
/// while that restart is deferred, then calls resetMetrics(at:) on restart.
/// No decision changes encoder settings in a running scrcpy server.
public struct AdaptiveQualityController: Sendable {
    public private(set) var ceiling: StreamQualityProfile
    public private(set) var currentProfile: StreamQualityProfile

    /// Failed recovery trials back off for this device/controller lifetime.
    /// A reconnect must not restart the same poor-path trial every minute.
    public var requiredHealthyDuration: TimeInterval {
        switch failedRecoveryProbes {
        case 0: 30
        case 1: 60
        case 2: 120
        default: 240
        }
    }

    private static let warmup: TimeInterval = 8
    private static let minimumDwell: TimeInterval = 15
    private static let recoveryProbeWindow: TimeInterval = 30
    private static let requiredPressureWindows = 2

    private struct RecoveryProbe: Sendable {
        var startedAt: TimeInterval
    }

    private var warmupEndsAt: TimeInterval
    private var lastChangeAt: TimeInterval
    private var lastObservationAt: TimeInterval
    private var pressureWindows = 0
    private var healthyActiveDuration: TimeInterval = 0
    private var failedRecoveryProbes = 0
    private var recoveryProbe: RecoveryProbe?

    public init(ceiling: StreamQualityProfile, initialProfile: StreamQualityProfile? = nil,
                now: TimeInterval) {
        self.ceiling = ceiling
        currentProfile = min(initialProfile ?? ceiling, ceiling)
        warmupEndsAt = now + Self.warmup
        lastChangeAt = now
        lastObservationAt = now
    }

    /// Discards startup/transient observations without resetting an adaptive
    /// choice or its dwell timer. Use a fresh controller for a different device.
    public mutating func resetMetrics(at now: TimeInterval) {
        guard now.isFinite, now >= lastObservationAt else { return }
        warmupEndsAt = now + Self.warmup
        lastObservationAt = now
        clearEvidence()
        // A deferred restart starts the trial when its new stream actually
        // starts, while previously failed trial history remains intact.
        if recoveryProbe != nil { recoveryProbe?.startedAt = now }
    }

    /// A lower user ceiling applies immediately. Raising it permits cautious
    /// recovery and does not erase evidence of a previously congested path.
    public mutating func setCeiling(_ ceiling: StreamQualityProfile,
                                   at now: TimeInterval) -> AdaptiveQualityDecision? {
        guard now.isFinite, now >= lastObservationAt else { return nil }
        self.ceiling = ceiling
        clearEvidence()
        lastObservationAt = now
        guard currentProfile > ceiling else { return nil }
        return change(to: ceiling, reason: .userCeiling, at: now)
    }

    public mutating func evaluate(sample: StreamPerformanceSample,
                                  at now: TimeInterval) -> AdaptiveQualityDecision? {
        guard now.isFinite, now > lastObservationAt else { return nil }
        let elapsed = now - lastObservationAt
        lastObservationAt = now

        guard sample.interval.isFinite, sample.interval > 0,
              sample.maximumPresentationDelay.isFinite, sample.streamBacklogGrowth.isFinite else {
            clearEvidence()
            return nil
        }
        guard now > warmupEndsAt else { clearEvidence(); return nil }

        // A suspended app or a missing sample must not count as sustained
        // healthy activity. Large windows also provide no consecutive-pressure
        // evidence. Resume collecting fresh, bounded windows instead.
        guard sample.interval <= 6, elapsed <= max(6, sample.interval * 1.5) else {
            clearEvidence()
            return nil
        }

        let completedFrames = max(0, sample.presentedFrames) + max(0, sample.droppedFrames)
        let dropFraction = Double(max(0, sample.droppedFrames)) / Double(max(1, completedFrames))
        let dropPressure = sample.droppedFrames >= 3 && dropFraction >= 0.20
        let overloaded = sample.maximumPresentationDelay >= 0.30
            || sample.streamBacklogGrowth >= max(0.12, sample.interval * 0.08)
            || sample.rendererFlushes > 0 || dropPressure

        if overloaded {
            pressureWindows += 1
            healthyActiveDuration = 0
            guard pressureWindows >= Self.requiredPressureWindows,
                  now - lastChangeAt >= Self.minimumDwell,
                  let lower = StreamQualityProfile(rawValue: currentProfile.rawValue - 1) else { return nil }
            return change(to: lower, reason: .sustainedPressure, at: now)
        }

        pressureWindows = 0
        let activeVideo = Double(max(0, sample.receivedFrames)) / sample.interval >= 15
            && Double(max(0, sample.presentedFrames)) / sample.interval >= 15
        // Counted mailbox drops are the primary signal; this also rejects a
        // lossy/incomplete decoder path whose missing frames were not counted.
        // The small allowance accommodates callbacks across window boundaries.
        let completionFraction = Double(max(0, sample.presentedFrames))
            / Double(max(1, sample.receivedFrames, sample.decodedFrames))
        let healthy = sample.maximumPresentationDelay <= 0.12
            && sample.streamBacklogGrowth <= 0.015 && dropFraction <= 0.02
            && sample.rendererFlushes == 0 && completionFraction >= 0.90
        guard activeVideo && healthy else {
            healthyActiveDuration = 0
            return nil
        }

        // Encoded bytes, target bitrate and a low content frame rate cannot
        // prove spare capacity. Only sustained, actively presented video allows
        // a one-level recovery trial, still capped by the user preference.
        healthyActiveDuration += min(sample.interval, elapsed, now - warmupEndsAt)
        guard healthyActiveDuration >= requiredHealthyDuration,
              now - lastChangeAt >= Self.minimumDwell,
              currentProfile < ceiling,
              let higher = StreamQualityProfile(rawValue: currentProfile.rawValue + 1) else { return nil }
        return change(to: higher, reason: .sustainedHealthyVideo, at: now)
    }

    private mutating func change(to profile: StreamQualityProfile,
                                 reason: AdaptiveQualityDecision.Reason,
                                 at now: TimeInterval) -> AdaptiveQualityDecision {
        let previous = currentProfile
        switch reason {
        case .sustainedPressure:
            if let recoveryProbe, now - recoveryProbe.startedAt <= Self.recoveryProbeWindow {
                failedRecoveryProbes = min(3, failedRecoveryProbes + 1)
            }
            recoveryProbe = nil
        case .sustainedHealthyVideo:
            recoveryProbe = RecoveryProbe(startedAt: now)
        case .userCeiling:
            recoveryProbe = nil
        }
        currentProfile = profile
        lastChangeAt = now
        warmupEndsAt = now + Self.warmup
        clearEvidence()
        return AdaptiveQualityDecision(previousProfile: previous, profile: profile, reason: reason)
    }

    private mutating func clearEvidence() {
        pressureWindows = 0
        healthyActiveDuration = 0
    }
}

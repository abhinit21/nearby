import Foundation
import NearbyCore

/// Serializes video-only restarts independently of connection recovery. Changes
/// made while starting/reconfiguring coalesce; late work cannot reopen a session.
@MainActor
final class VideoQualityCoordinator {
    var onChange: (() -> Void)?
    var applyProfile: ((StreamQualityProfile, UUID) async -> Bool)?
    private(set) var currentProfile: StreamQualityProfile?
    private(set) var latestSample: StreamPerformanceSample?
    private(set) var isApplying = false
    private(set) var automatic = true
    private var controller: AdaptiveQualityController?
    private var generation: UUID?
    private var ready = false
    private var pendingProfile: StreamQualityProfile?
    private var operation = UUID()
    private var task: Task<Void, Never>?
    private let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    var profileForStart: StreamQualityProfile? { controller?.currentProfile }

    func open(generation: UUID, ceiling: StreamQualityProfile, automatic: Bool) {
        close()
        self.generation = generation
        self.automatic = automatic
        controller = AdaptiveQualityController(ceiling: ceiling, now: clock())
        currentProfile = ceiling
        onChange?()
    }

    func configure(ceiling: StreamQualityProfile, automatic: Bool) {
        guard var controller else { self.automatic = automatic; return }
        let now = clock()
        if !automatic {
            controller = AdaptiveQualityController(ceiling: ceiling, now: now)
        } else if !self.automatic {
            controller = AdaptiveQualityController(ceiling: ceiling, initialProfile: currentProfile, now: now)
        } else {
            _ = controller.setCeiling(ceiling, at: now)
        }
        self.automatic = automatic
        self.controller = controller
        pendingProfile = controller.currentProfile == currentProfile && !isApplying ? nil : controller.currentProfile
        onChange?()
        drain()
    }

    func streamStarted(profile: StreamQualityProfile) {
        guard generation != nil else { return }
        currentProfile = profile
        controller?.resetMetrics(at: clock())
        ready = true
        if pendingProfile == profile { pendingProfile = nil }
        onChange?()
        drain()
    }

    func receive(_ sample: StreamPerformanceSample, generation: UUID) {
        guard self.generation == generation, ready else { return }
        latestSample = sample
        if automatic, task == nil, pendingProfile == nil,
           let decision = controller?.evaluate(sample: sample, at: clock()) {
            pendingProfile = decision.profile
        }
        onChange?()
        drain()
    }

    /// A real interruption keeps the adaptive choice for recovery, but revokes
    /// any in-flight video restart and all observations from the old stream.
    func suspend() {
        ready = false
        operation = UUID()
        task?.cancel(); task = nil
        isApplying = false
        latestSample = nil
        onChange?()
    }

    func close() {
        suspend()
        generation = nil
        controller = nil
        pendingProfile = nil
        currentProfile = nil
        onChange?()
    }

    private func drain() {
        guard ready, task == nil, let generation, let profile = pendingProfile, let applyProfile else { return }
        pendingProfile = nil
        guard profile != currentProfile else { return }
        let token = UUID(); operation = token
        isApplying = true
        task = Task { [weak self] in
            let applied = await applyProfile(profile, generation)
            guard let self, !Task.isCancelled, operation == token, self.generation == generation else { return }
            task = nil; isApplying = false
            if applied {
                currentProfile = profile
                controller?.resetMetrics(at: clock())
            } else {
                // Recovery or a later first frame makes the coordinator ready
                // again; never run an automatic retry loop of our own.
                ready = false
            }
            onChange?()
            drain()
        }
        onChange?()
    }
}

extension StreamQualityProfile {
    var displayName: String {
        switch self {
        case .high: "High Quality"
        case .balanced: "Balanced"
        case .efficient: "Lower Bandwidth"
        case .constrained: "Minimum Bandwidth"
        }
    }

    var streamOptions: StreamOptions {
        StreamOptions(maxSize: maxSize, bitRate: bitRate, maxFPS: maxFPS, audio: false)
    }
}

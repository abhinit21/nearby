import Foundation

/// A monotonic token bucket for source bytes, excluding SYNC protocol messages.
/// Keeping the policy separate from socket waiting makes rate behavior testable
/// without waiting for wall-clock time or depending on loopback throughput.
struct UploadTokenBucket: Sendable {
    static let maximumBurstBytes = 65_536
    let burstBytes: Int
    private(set) var bytesPerSecond: Int?
    private var tokens: Double
    private var updatedAt: TimeInterval?

    init(bytesPerSecond: Int?, burstBytes: Int = maximumBurstBytes) {
        precondition((1...Self.maximumBurstBytes).contains(burstBytes))
        self.burstBytes = burstBytes
        self.bytesPerSecond = bytesPerSecond.map { max(1, $0) }
        tokens = Double(burstBytes)
    }

    mutating func setRateLimit(bytesPerSecond: Int?, at now: TimeInterval) {
        refill(at: now)
        self.bytesPerSecond = bytesPerSecond.map { max(1, $0) }
        if bytesPerSecond == nil { tokens = Double(burstBytes) }
    }

    /// Zero grants and consumes the requested budget. A positive result is the
    /// earliest retry time, in seconds; it reserves nothing while the caller waits.
    mutating func consume(_ byteCount: Int, at now: TimeInterval) -> TimeInterval {
        precondition((0...burstBytes).contains(byteCount))
        refill(at: now)
        guard let bytesPerSecond else { return 0 }
        guard tokens >= Double(byteCount) else {
            return (Double(byteCount) - tokens) / Double(bytesPerSecond)
        }
        tokens -= Double(byteCount)
        return 0
    }

    private mutating func refill(at now: TimeInterval) {
        defer { updatedAt = max(updatedAt ?? now, now) }
        guard let updatedAt, let bytesPerSecond else { return }
        tokens = min(Double(burstBytes), tokens + max(0, now - updatedAt) * Double(bytesPerSecond))
    }
}

/// Shared across transfers so each new file cannot obtain a fresh burst. Rate
/// changes from the main actor take effect at the next socket pacing check.
final class UploadPacing: @unchecked Sendable {
    private let lock = NSLock()
    private var bucket: UploadTokenBucket

    init(bytesPerSecond: Int? = nil) {
        bucket = UploadTokenBucket(bytesPerSecond: bytesPerSecond)
    }

    var bytesPerSecond: Int? {
        lock.lock(); defer { lock.unlock() }
        return bucket.bytesPerSecond
    }

    func setRateLimit(bytesPerSecond: Int?) {
        lock.lock(); defer { lock.unlock() }
        bucket.setRateLimit(bytesPerSecond: bytesPerSecond, at: ProcessInfo.processInfo.systemUptime)
    }

    func consume(_ byteCount: Int) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return bucket.consume(byteCount, at: ProcessInfo.processInfo.systemUptime)
    }
}

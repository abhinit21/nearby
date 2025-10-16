import Foundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo

func scrcpyMonotonicTime() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

/// A single decoded frame may wait for presentation. Compressed access units are
/// never dropped: subsequent H.264 pictures may depend on all preceding ones.
struct DecodedVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let receivedAt: TimeInterval
    let submittedAt: TimeInterval
}

/// Build the display sample off the UI thread too. The main actor only updates
/// observable dimensions and hands this already-prepared sample to the renderer.
struct PreparedVideoFrame: @unchecked Sendable {
    let decoded: DecodedVideoFrame
    let sample: CMSampleBuffer
    let size: CGSize

    init?(_ decoded: DecodedVideoFrame) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: decoded.pixelBuffer, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: decoded.pixelBuffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        self.decoded = decoded; self.sample = sample
        size = CGSize(width: CVPixelBufferGetWidth(decoded.pixelBuffer), height: CVPixelBufferGetHeight(decoded.pixelBuffer))
    }
}

/// One pending value and one outstanding drain, regardless of producer speed.
/// A drain takes one value, yields back to its executor, and schedules another
/// turn only if finishDrain finds a newer value. This avoids both lost wakeups
/// and an unbounded loop monopolizing the main actor under continuous input.
final class LatestFrameMailbox<Value: Sendable>: @unchecked Sendable {
    struct Offer: Equatable {
        let accepted: Bool
        let replaced: Bool
        let shouldSchedule: Bool
    }
    private let lock = NSLock()
    private var pending: Value?
    private var draining = false
    private var closed = false

    func offer(_ value: Value) -> Offer {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return Offer(accepted: false, replaced: false, shouldSchedule: false) }
        let replaced = pending != nil
        pending = value
        let schedule = !draining
        draining = true
        return Offer(accepted: true, replaced: replaced, shouldSchedule: schedule)
    }

    func takeForDrain() -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        let value = pending; pending = nil
        return value
    }

    func finishDrain() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !closed, pending != nil { return true }
        draining = false
        return false
    }

    func close() {
        lock.lock(); closed = true; pending = nil; draining = false; lock.unlock()
    }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending == nil ? 0 : 1 }
}

/// Counters cross decoder, video reader, and presentation threads. Both Android
/// PTS and Mac uptime have arbitrary origins; only changes in their relative
/// elapsed times can indicate growing stream backlog, never absolute latency.
final class ScrcpyPerformanceCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var intervalStart: TimeInterval
    private var encodedBytes = 0
    private var receivedFrames = 0
    private var decodedFrames = 0
    private var presentedFrames = 0
    private var droppedFrames = 0
    private var rendererFlushes = 0
    private var maximumPresentationDelay: TimeInterval = 0
    private var firstArrival: TimeInterval?
    private var firstPTS: UInt64?
    private var previousPTS: UInt64?
    private var relativeArrivalOffset: TimeInterval = 0
    private var intervalArrivalOffset: TimeInterval = 0

    init(now: TimeInterval = scrcpyMonotonicTime()) { intervalStart = now }

    func received(bytes: Int, header: ScrcpyFrameHeader, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        encodedBytes += bytes
        guard !header.isConfiguration else { return }
        receivedFrames += 1
        let pts = header.presentationTime
        if firstPTS == nil || previousPTS.map({ pts < $0 }) == true {
            firstPTS = pts; firstArrival = now
            relativeArrivalOffset = 0; intervalArrivalOffset = 0
        }
        if let firstPTS, let firstArrival {
            relativeArrivalOffset = (now - firstArrival) - TimeInterval(pts - firstPTS) / 1_000_000
        }
        previousPTS = pts
    }

    func decoded() { lock.lock(); decodedFrames += 1; lock.unlock() }
    func dropped() { lock.lock(); droppedFrames += 1; lock.unlock() }
    func presented(receivedAt: TimeInterval, at now: TimeInterval, flushed: Bool) {
        lock.lock(); defer { lock.unlock() }
        presentedFrames += 1
        maximumPresentationDelay = max(maximumPresentationDelay, max(0, now - receivedAt))
        if flushed { rendererFlushes += 1 }
    }

    func takeSample(at now: TimeInterval = scrcpyMonotonicTime()) -> StreamPerformanceSample {
        lock.lock(); defer { lock.unlock() }
        let sample = StreamPerformanceSample(encodedBytes: encodedBytes, receivedFrames: receivedFrames,
            decodedFrames: decodedFrames, presentedFrames: presentedFrames, droppedFrames: droppedFrames,
            maximumPresentationDelay: maximumPresentationDelay,
            streamBacklogGrowth: max(0, relativeArrivalOffset - intervalArrivalOffset),
            rendererFlushes: rendererFlushes, interval: max(0, now - intervalStart))
        intervalStart = now; intervalArrivalOffset = relativeArrivalOffset
        encodedBytes = 0; receivedFrames = 0; decodedFrames = 0; presentedFrames = 0
        droppedFrames = 0; rendererFlushes = 0; maximumPresentationDelay = 0
        return sample
    }
}

/// Blocking socket reads and H.264 parsing/submission live on one dedicated
/// serial queue, outside the UI actor and Swift's cooperative executor pool.
/// VideoDecoder finishes each access unit before the next one is read, bounding
/// hardware submissions as well as the decoded presentation mailbox.
final class ScrcpyVideoWorker: @unchecked Sendable {
    private final class JoinWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?
        func install(_ value: CheckedContinuation<Void, Never>) {
            lock.lock()
            if finished { lock.unlock(); value.resume(); return }
            continuation = value; lock.unlock()
        }
        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let value = continuation; continuation = nil; lock.unlock()
            value?.resume()
        }
    }
    let frames = LatestFrameMailbox<PreparedVideoFrame>()
    let performance = ScrcpyPerformanceCounters()
    private let queue = DispatchQueue(label: "Nearby.scrcpy.video", qos: .userInteractive)
    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var cancelled = false
    private var videoSocket: ScrcpySocket?
    private let owned: ScrcpyResources
    private let onConnected: @Sendable (ScrcpySocket, CGSize) -> Void
    private let onDeviceMessage: @Sendable (ScrcpyDeviceMessage) -> Void
    private let onFrameAvailable: @Sendable () -> Void
    private let onError: @Sendable (String) -> Void
    private let processingObserver: (@Sendable () -> Void)?

    init(owned: ScrcpyResources,
         onConnected: @escaping @Sendable (ScrcpySocket, CGSize) -> Void,
         onDeviceMessage: @escaping @Sendable (ScrcpyDeviceMessage) -> Void,
         onFrameAvailable: @escaping @Sendable () -> Void,
         onError: @escaping @Sendable (String) -> Void,
         processingObserver: (@Sendable () -> Void)? = nil) {
        self.owned = owned; self.onConnected = onConnected; self.onDeviceMessage = onDeviceMessage
        self.onFrameAvailable = onFrameAvailable; self.onError = onError
        self.processingObserver = processingObserver
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func start(port: UInt16, deadline: Date) {
        completion.enter()
        queue.async { [self] in
            let decoder = VideoDecoder(onDecodedFrame: { [self] frame in
                performance.decoded()
                guard let prepared = PreparedVideoFrame(frame) else { performance.dropped(); return }
                let offer = frames.offer(prepared)
                if offer.replaced { performance.dropped() }
                if offer.shouldSchedule { onFrameAvailable() }
            }, onError: { [self] status in
                if !isCancelled, !owned.isClosed { onError("The native video decoder stopped (\(status)).") }
            }, onDroppedFrame: { [self] in performance.dropped() })
            defer {
                decoder.invalidate()
                completion.leave()
            }
            do {
                let video = try connectVideo(port: port, deadline: deadline)
                try install(video)
                let controls = try ScrcpySocket(port: port); try owned.add(controls)
                _ = try video.readExactly(64)
                let metadata = try video.readExactly(12)
                guard metadata.uint32BE(at: 0) == 0x68323634 else {
                    throw ScrcpyProtocolError.malformed("The phone did not provide an H.264 stream.")
                }
                let width = Int(metadata.uint32BE(at: 4)), height = Int(metadata.uint32BE(at: 8))
                guard width > 0, height > 0, width <= 16384, height <= 16384 else {
                    throw ScrcpyProtocolError.malformed("Invalid phone video dimensions.")
                }
                video.readTimeout(0)
                onConnected(controls, CGSize(width: width, height: height))
                readDeviceMessages(controls)
                while !isCancelled, !owned.isClosed {
                    // This dispatch block lasts for the whole stream; release
                    // temporary bridged/native objects after every access unit.
                    try autoreleasepool {
                        let header = try ScrcpyFrameHeader(video.readExactly(12))
                        let packet = try video.readExactly(header.payloadSize)
                        let receivedAt = scrcpyMonotonicTime()
                        guard !isCancelled, !owned.isClosed else { return }
                        performance.received(bytes: packet.count + 12, header: header, at: receivedAt)
                        processingObserver?()
                        try decoder.decode(packet, header: header, receivedAt: receivedAt)
                    }
                }
            } catch {
                if !isCancelled, !owned.isClosed { onError(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let socket = videoSocket; videoSocket = nil; lock.unlock()
        frames.close()
        socket?.close() // Interrupt read immediately, leaving the final control write available.
    }

    func waitUntilStopped() async {
        let waiter = JoinWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
                completion.notify(queue: .global(qos: .utility)) { waiter.finish() }
            }
        } onCancel: {
            waiter.finish()
        }
    }

    private func install(_ video: ScrcpySocket) throws {
        lock.lock()
        guard !cancelled else { lock.unlock(); video.close(); throw CancellationError() }
        videoSocket = video; lock.unlock()
    }

    private func connectVideo(port: UInt16, deadline: Date) throws -> ScrcpySocket {
        while Date() < deadline, !isCancelled, !owned.isClosed {
            do {
                let socket = try ScrcpySocket(port: port)
                socket.readTimeout(1)
                guard try socket.readExactly(1) == Data([0]) else { socket.close(); continue }
                socket.readTimeout(3)
                try owned.add(socket)
                return socket
            } catch {
                if isCancelled || owned.isClosed { throw CancellationError() }
                Thread.sleep(forTimeInterval: 0.08)
            }
        }
        throw ScrcpyProtocolError.malformed("The Android mirroring server did not become ready. \(owned.logs)")
    }

    private func readDeviceMessages(_ controls: ScrcpySocket) {
        // A second blocking socket must not occupy a cooperative Swift thread.
        completion.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { completion.leave() }
            var parser = ScrcpyDeviceMessageParser()
            do {
                while !isCancelled, !owned.isClosed {
                    for message in try parser.append(controls.readAvailable()) { onDeviceMessage(message) }
                }
            } catch {
                if !isCancelled, !owned.isClosed { onError(error.localizedDescription) }
            }
        }
    }
}

import Foundation
@preconcurrency import VideoToolbox
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo

/// Annex-B H.264 access units from the pinned scrcpy server, decoded natively.
final class VideoDecoder: @unchecked Sendable {
    private final class Output: @unchecked Sendable {
        let handler: @Sendable (DecodedVideoFrame) -> Void
        let errorHandler: @Sendable (OSStatus) -> Void
        let droppedHandler: @Sendable () -> Void
        init(_ handler: @escaping @Sendable (DecodedVideoFrame) -> Void,
             errorHandler: @escaping @Sendable (OSStatus) -> Void,
             droppedHandler: @escaping @Sendable () -> Void = {}) {
            self.handler = handler; self.errorHandler = errorHandler; self.droppedHandler = droppedHandler
        }
    }
    private final class FrameTiming {
        let receivedAt: TimeInterval
        let submittedAt: TimeInterval
        init(receivedAt: TimeInterval, submittedAt: TimeInterval) {
            self.receivedAt = receivedAt; self.submittedAt = submittedAt
        }
    }
    private let lock = NSRecursiveLock()
    private let output: Output
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    init(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void, onError: @escaping @Sendable (OSStatus) -> Void = { _ in }) {
        output = Output({ onFrame($0.pixelBuffer) }, errorHandler: onError)
    }
    init(onDecodedFrame: @escaping @Sendable (DecodedVideoFrame) -> Void,
         onError: @escaping @Sendable (OSStatus) -> Void = { _ in },
         onDroppedFrame: @escaping @Sendable () -> Void = {}) {
        output = Output(onDecodedFrame, errorHandler: onError, droppedHandler: onDroppedFrame)
    }
    deinit { invalidate() }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil; format = nil; sps = nil; pps = nil
    }

    func decode(_ bytes: Data, header: ScrcpyFrameHeader, receivedAt: TimeInterval = scrcpyMonotonicTime()) throws {
        lock.lock(); defer { lock.unlock() }
        let units = Self.nalUnits(in: bytes)
        guard !units.isEmpty else { throw ScrcpyProtocolError.malformed("Invalid H.264 access unit.") }
        var changed = false
        for unit in units {
            switch unit.first.map({ $0 & 0x1f }) {
            case 7: if sps != unit { sps = unit; changed = true }
            case 8: if pps != unit { pps = unit; changed = true }
            default: break
            }
        }
        if changed || session == nil, let sps, let pps { try configure(sps: sps, pps: pps) }
        guard !header.isConfiguration, let session, let format else { return }
        let payload = Self.lengthPrefixed(units)
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block), "allocate video packet")
        guard let block else { return }
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            try check(CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0,
                                                    dataLength: payload.count), "copy video packet")
        }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(header.presentationTime), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = payload.count
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), "create video sample")
        guard let sample else { return }
        var info = VTDecodeInfoFlags()
        let frameTiming = FrameTiming(receivedAt: receivedAt, submittedAt: scrcpyMonotonicTime())
        try withExtendedLifetime(frameTiming) {
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                flags: [],
                frameRefcon: Unmanaged.passUnretained(frameTiming).toOpaque(), infoFlagsOut: &info)
            // With both asynchronous and temporal flags clear, VideoToolbox
            // guarantees the output callback completes before this call returns.
            // This bounds decoder work to one access unit and keeps source
            // timing alive. Production invokes it only on the video worker.
            try check(status, "decode video")
        }
    }

    private func configure(sps: Data, pps: Data) throws {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        try check(status, "read H.264 configuration")
        guard let description else { throw ScrcpyProtocolError.malformed("Missing H.264 format.") }
        format = description
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, source, status, _, image, _, _ in
            guard let refcon else { return }
            let output = Unmanaged<Output>.fromOpaque(refcon).takeUnretainedValue()
            guard status == noErr else { output.errorHandler(status); return }
            if let image, let source {
                let timing = Unmanaged<FrameTiming>.fromOpaque(source).takeUnretainedValue()
                output.handler(DecodedVideoFrame(pixelBuffer: image, receivedAt: timing.receivedAt, submittedAt: timing.submittedAt))
            } else { output.droppedHandler() }
        }, decompressionOutputRefCon: Unmanaged.passUnretained(output).toOpaque())
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &session), "start native video decoder")
        if let session { VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw ScrcpyProtocolError.malformed("Could not \(operation) (\(status)).") }
    }

    static func nalUnits(in bytes: Data) -> [Data] {
        let bytes = [UInt8](bytes)
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        return starts.enumerated().compactMap { index, start in
            let lower = start.0 + start.1
            let upper = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            return lower < upper ? Data(bytes[lower..<upper]) : nil
        }
    }

    static func lengthPrefixed(_ units: [Data]) -> Data {
        var result = Data()
        for unit in units { result.appendBE(UInt32(unit.count)); result.append(unit) }
        return result
    }
}

import Foundation

public enum TouchPhase: Sendable { case down, move, up }

/// Wire layout pinned to scrcpy v3.3.4 ControlMessageReader.java/control_msg.c.
enum ControlProtocol {
    static func keycode(_ code: UInt32, down: Bool, metaState: UInt32 = 0) -> Data {
        var data = Data([0, down ? 0 : 1])
        data.appendBE(code); data.appendBE(UInt32(0)); data.appendBE(metaState)
        return data
    }

    static func text(_ text: String) -> Data {
        var data = Data([1])
        let bytes = utf8Prefix(text, limit: 300)
        data.appendBE(UInt32(bytes.count)); data.append(bytes)
        return data
    }

    static func touch(x: Double, y: Double, width: Int, height: Int, phase: TouchPhase) -> Data {
        let action: UInt8 = phase == .down ? 0 : phase == .up ? 1 : 2
        var data = Data([2, action])
        data.appendBE(UInt64.max - 1) // scrcpy's generic finger, not its mouse pointer.
        appendPosition(&data, x: x, y: y, width: width, height: height)
        data.appendBE(phase == .up ? UInt16(0) : UInt16.max)
        data.appendBE(UInt32(0)); data.appendBE(UInt32(0))
        return data
    }

    static func scroll(x: Double, y: Double, width: Int, height: Int, dx: Double, dy: Double) -> Data {
        var data = Data([3])
        appendPosition(&data, x: x, y: y, width: width, height: height)
        data.appendBE(UInt16(bitPattern: fixedScroll(dx)))
        data.appendBE(UInt16(bitPattern: fixedScroll(dy)))
        data.appendBE(UInt32(0))
        return data
    }

    static func clipboard(_ text: String, paste: Bool, sequence: UInt64 = 0) throws -> Data {
        let bytes = Data(text.utf8)
        guard bytes.count <= ClipboardTransferLimits.maximumTextBytes else { throw ClipboardFailure.tooLarge }
        var data = Data([9]); data.appendBE(sequence); data.append(paste ? 1 : 0)
        data.appendBE(UInt32(bytes.count)); data.append(bytes)
        return data
    }

    static func screenPower(_ on: Bool) -> Data { Data([10, on ? 1 : 0]) }

    private static func appendPosition(_ data: inout Data, x: Double, y: Double, width: Int, height: Int) {
        let w = min(65535, max(1, width)), h = min(65535, max(1, height))
        func coordinate(_ value: Double, dimension: Int) -> UInt32 {
            let value = value.isFinite ? value : 0
            return UInt32(min(dimension - 1, max(0, Int((min(1, max(0, value)) * Double(dimension)).rounded(.down)))))
        }
        data.appendBE(coordinate(x, dimension: w)); data.appendBE(coordinate(y, dimension: h))
        data.appendBE(UInt16(w)); data.appendBE(UInt16(h))
    }

    private static func fixedScroll(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(clamping: Int((min(16, max(-16, value)) / 16 * 32768).rounded(.towardZero)))
    }

    static func utf8Prefix(_ text: String, limit: Int) -> Data {
        var data = Data()
        for scalar in text.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            guard data.count + bytes.count <= limit else { break }
            data.append(bytes)
        }
        return data
    }
}

enum ScrcpyProtocolError: LocalizedError {
    case malformed(String)
    var errorDescription: String? { if case .malformed(let message) = self { return message }; return nil }
}

struct ScrcpyFrameHeader: Equatable {
    let isConfiguration: Bool
    let isKeyFrame: Bool
    let presentationTime: UInt64
    let payloadSize: Int
    init(_ bytes: Data) throws {
        guard bytes.count == 12 else { throw ScrcpyProtocolError.malformed("Invalid video packet header.") }
        let flags = bytes.uint64BE(at: 0)
        isConfiguration = flags & (1 << 63) != 0
        isKeyFrame = flags & (1 << 62) != 0
        presentationTime = flags & ((1 << 62) - 1)
        payloadSize = Int(bytes.uint32BE(at: 8))
        guard (1...(16 * 1024 * 1024)).contains(payloadSize) else {
            throw ScrcpyProtocolError.malformed("Video packet exceeds the supported size.")
        }
    }
}

enum ScrcpyDeviceMessage: Equatable {
    case clipboard(String)
    case clipboardAcknowledgement(UInt64)
}

struct ScrcpyDeviceMessageParser {
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws -> [ScrcpyDeviceMessage] {
        buffer.append(bytes)
        guard buffer.count <= (1 << 20) else { throw ScrcpyProtocolError.malformed("Device message is too large.") }
        var messages: [ScrcpyDeviceMessage] = []
        while let type = buffer.first {
            let length: Int
            switch type {
            case 0:
                guard buffer.count >= 5 else { return messages }
                let size = Int(buffer.uint32BE(at: 1))
                guard size <= (1 << 18) else { throw ScrcpyProtocolError.malformed("Clipboard message is too large.") }
                length = 5 + size
                guard buffer.count >= length else { return messages }
                guard let text = String(data: buffer.subdata(in: 5..<length), encoding: .utf8) else {
                    throw ScrcpyProtocolError.malformed("The phone sent invalid clipboard text.")
                }
                messages.append(.clipboard(text))
            case 1:
                length = 9
                guard buffer.count >= length else { return messages }
                messages.append(.clipboardAcknowledgement(buffer.uint64BE(at: 1)))
            case 2:
                guard buffer.count >= 5 else { return messages }
                length = 5 + Int(buffer.uint16BE(at: 3)) // UHID output (not used by this client).
            default: throw ScrcpyProtocolError.malformed("Unknown scrcpy device message: \(type).")
            }
            guard buffer.count >= length else { return messages }
            buffer = Data(buffer.dropFirst(length))
        }
        return messages
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
    func uint16BE(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) << 8 | UInt16(self[start + 1])
    }
    func uint32BE(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return (0..<4).reduce(0) { ($0 << 8) | UInt32(self[start + $1]) }
    }
    func uint64BE(at offset: Int) -> UInt64 {
        let start = startIndex + offset
        return (0..<8).reduce(0) { ($0 << 8) | UInt64(self[start + $1]) }
    }
}

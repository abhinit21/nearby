import Foundation
import Security

public enum DeviceState: String, Codable, Sendable {
    case available, unavailable, searching, connecting, mirroring, unauthorized
    public var displayLabel: String {
        switch self {
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .searching: "Searching…"
        case .connecting: "Connecting…"
        case .mirroring: "Mirroring"
        case .unauthorized: "Allow debugging on your Pixel"
        }
    }
}

public struct DeviceRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var serial: String
    public var name: String
    public var state: DeviceState
    public var imagePath: String?
    public var isWireless: Bool
    /// A Bonjour name learned only after a transport's hardware ID was read.
    public var discoveryServiceName: String?
    public init(id: String, serial: String, name: String, state: DeviceState = .available, imagePath: String? = nil, isWireless: Bool = true, discoveryServiceName: String? = nil) {
        self.id = id; self.serial = serial; self.name = name; self.state = state
        self.imagePath = imagePath; self.isWireless = isWireless; self.discoveryServiceName = discoveryServiceName
    }
}

public struct PairingService: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
    public init(id: String, name: String, host: String, port: Int) {
        self.id = id; self.name = name; self.host = host; self.port = port
    }
}

public struct ADBDevice: Sendable, Equatable {
    public var serial: String
    public var status: String
    public var model: String
    public var isWireless: Bool
    public static func parse(_ output: String) -> [ADBDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, ["device", "offline", "unauthorized", "recovery", "sideload"].contains(fields[1]) else { return nil }
            let serial = fields[0]
            let model = fields.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? "Android device"
            return ADBDevice(serial: serial, status: fields[1], model: model, isWireless: serial.contains(":") || serial.contains("_adb-tls-connect"))
        }
    }
}

public enum PairingCode {
    public static func normalized(_ value: String) -> String? {
        let digits = value.filter { !$0.isWhitespace }
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return digits
    }
}

public struct QRPairingAttempt: Sendable {
    public let serviceName: String
    public let secret: String
    public var payload: String { "WIFI:T:ADB;S:\(serviceName);P:\(secret);;" }
    public init() throws {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ADBError.command("Couldn't generate a secure pairing code. Please try again.")
        }
        serviceName = "studio-" + bytes.prefix(8).map { String(format: "%02x", $0) }.joined()
        secret = bytes.dropFirst(8).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ConnectionAddress: Sendable, Equatable {
    public let value: String
    public init(_ input: String) throws {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.hasPrefix("-"), !address.contains(where: \.isWhitespace), address.utf8.count < 300 else {
            throw ADBError.command("Enter an address and port, for example 192.168.1.12:37123.")
        }
        let host: String, portText: String
        if address.hasPrefix("["), let closing = address.firstIndex(of: "]"), address.index(after: closing) < address.endIndex, address[address.index(after: closing)] == ":" {
            host = String(address[address.index(after: address.startIndex)..<closing])
            portText = String(address[address.index(closing, offsetBy: 2)...])
        } else {
            guard let colon = address.lastIndex(of: ":"), !address[..<colon].contains(":") else {
                throw ADBError.command("Include the port shown in Wireless debugging. Put IPv6 addresses in brackets.")
            }
            host = String(address[..<colon]); portText = String(address[address.index(after: colon)...])
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:%_")
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains), let port = Int(portText), (1...65535).contains(port), portText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw ADBError.command("The address or port isn't valid. Use the address shown on your Pixel.")
        }
        self.value = address
    }
}

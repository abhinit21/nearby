import Foundation

/// User-visible failures retain useful diagnostics without disclosing a QR secret.
public struct PairingFailure: Sendable {
    public let message: String
    public let detail: String
    public init(error: any Error, secret: String) {
        let raw = error.localizedDescription
        var safe = raw.replacingOccurrences(of: secret, with: "[redacted]", options: .caseInsensitive)
        safe = safe.replacingOccurrences(of: "[A-Fa-f0-9]{16,}", with: "[redacted]", options: .regularExpression)
        detail = String(safe.prefix(1200))
        let lower = raw.lowercased()
        if lower.contains("cannot connect to daemon") || lower.contains("cannot start server on remote host") {
            message = "Nearby's Android connection service stopped. Restart the service, then leave the Pixel's old pairing screen and scan a fresh QR code."
        } else if lower.contains("permission") || lower.contains("not permitted") || lower.contains("not authorized") {
            message = "macOS blocked the connection. Allow Nearby in System Settings → Privacy & Security → Local Network, then scan a fresh QR code."
        } else if lower.contains("route to host") || lower.contains("unreachable") || lower.contains("refused") {
            message = "Your Mac couldn't reach the Pixel's pairing service. Keep both devices on the same Wi-Fi, leave the old pairing screen, and scan a fresh QR code."
        } else if lower.contains("time") {
            message = "Pairing timed out. Leave the Pixel's old pairing screen, refresh this QR code, and scan again."
        } else {
            message = "Pairing didn't complete. Leave the Pixel's old pairing screen and try a fresh QR code."
        }
    }
}

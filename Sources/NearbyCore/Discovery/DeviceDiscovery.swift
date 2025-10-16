import Foundation
import Darwin

/// Bonjour finds Android's TLS pairing service and its distinct authorized connection service.
@MainActor
public final class DeviceDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    public var onChange: (([PairingService], [PairingService]) -> Void)?
    public var onError: ((String) -> Void)?
    private var browsers: [NetServiceBrowser] = []
    private var resolving: [String: NetService] = [:]
    private var pairing: [String: PairingService] = [:]
    private var connecting: [String: PairingService] = [:]
    public override init() { super.init() }
    public func start() {
        guard browsers.isEmpty else { return }
        for type in ["_adb-tls-pairing._tcp.", "_adb-tls-connect._tcp."] {
            let browser = NetServiceBrowser(); browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }
    public func stop() {
        browsers.forEach { $0.delegate = nil; $0.stop() }; browsers.removeAll()
        resolving.values.forEach { $0.delegate = nil; $0.stop() }; resolving.removeAll()
        pairing.removeAll(); connecting.removeAll()
    }
    /// Flushes resolved addresses after wake or a network change. A late resolve
    /// from a stopped generation cannot repopulate the endpoint cache.
    public func restart() {
        stop(); publish(); start()
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browsers.contains(where: { $0 === browser }) else { return }
        let id = key(service); resolving[id] = service; service.delegate = self; service.resolve(withTimeout: 8)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browsers.contains(where: { $0 === browser }) else { return }
        let id = key(service); resolving.removeValue(forKey: id)?.stop()
        pairing.removeValue(forKey: id); connecting.removeValue(forKey: id); publish()
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browsers.contains(where: { $0 === browser }) else { return }
        onError?("Local device discovery is unavailable. Allow Nearby in System Settings → Privacy & Security → Local Network, or use Connection Help.")
    }
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard resolving[key(sender)] === sender else { return }
        guard sender.port > 0, let host = numericHost(sender) ?? sender.hostName else { return }
        let id = key(sender), service = PairingService(id: id, name: sender.name, host: host, port: sender.port)
        if sender.type.contains("_adb-tls-pairing") { pairing[id] = service } else { connecting[id] = service }
        publish()
    }
    private func publish() {
        onChange?(pairing.values.sorted { $0.name < $1.name }, connecting.values.sorted { $0.name < $1.name })
    }
    private func key(_ s: NetService) -> String { s.type + "/" + s.name }
    private func numericHost(_ s: NetService) -> String? {
        let addresses = (s.addresses ?? []).sorted { a, b in
            let af = a.withUnsafeBytes { $0.load(as: sockaddr.self).sa_family }
            let bf = b.withUnsafeBytes { $0.load(as: sockaddr.self).sa_family }
            return af == AF_INET && bf != AF_INET
        }
        for data in addresses {
            let name: String? = data.withUnsafeBytes { raw in
                guard let pointer = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(pointer, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return result == 0 ? String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
            }
            if let name, !name.hasPrefix("fe80:") { return name }
        }
        return nil
    }
}

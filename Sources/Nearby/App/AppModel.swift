import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
import ServiceManagement
import NearbyCore
import OSLog
import Network

public enum PairingMode: String, CaseIterable { case qr, code }
private enum RecoveryProbeInterruption: Error { case endpointsChanged }

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [DeviceRecord] = []
    @Published var isSearching = false
    @Published var hasCompletedInitialDiscovery = false
    @Published var pairingMode: PairingMode = .qr { didSet { pairingError = nil; if pairingMode == .qr { refreshQR() } else { invalidatePairing() } } }
    @Published var pairingCode = ""
    @Published var pairingStatus = "Waiting for your Pixel…"
    @Published var pairingError: String?
    @Published var pairingDiagnostic: String?
    @Published var runtimeStatus: String? = "Starting Android connection service…"
    @Published var isPairing = false
    @Published var qrImage: NSImage?
    @Published var pairingServices: [PairingService] = []
    @Published var selectedPairingServiceID = ""
    @Published var errorMessage: String?
    @Published var showDeveloperHelp = false
    @Published var showConnectionHelp = false
    @Published var playAudio = false // Audio is explicitly disabled in this build's UI.
    @Published var shareClipboard = UserDefaults.standard.object(forKey: "shareClipboard") as? Bool ?? true { didSet { UserDefaults.standard.set(shareClipboard, forKey: "shareClipboard"); sharing.refreshContext() } }
    @Published var turnOffDisplay = UserDefaults.standard.bool(forKey: "turnOffDisplay") { didSet { UserDefaults.standard.set(turnOffDisplay, forKey: "turnOffDisplay"); session?.setScreenPower(!turnOffDisplay) } }
    @Published var resumeSessions = UserDefaults.standard.object(forKey: "resumeSessions") as? Bool ?? true { didSet { UserDefaults.standard.set(resumeSessions, forKey: "resumeSessions"); if !resumeSessions && isReconnecting { cancelConnection() } } }
    @Published var showMenuBar = UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true { didSet { UserDefaults.standard.set(showMenuBar, forKey: "showMenuBar"); onUISettingsChanged?() } }
    @Published var launchAtLogin = false { didSet { updateLoginItem() } }
    @Published var quality = UserDefaults.standard.string(forKey: "quality") ?? "Balanced" { didSet { UserDefaults.standard.set(quality, forKey: "quality"); qualityPreferencesChanged() } }
    @Published var adaptiveQuality = UserDefaults.standard.object(forKey: "adaptiveQuality") as? Bool ?? true { didSet { UserDefaults.standard.set(adaptiveQuality, forKey: "adaptiveQuality"); qualityPreferencesChanged() } }
    @Published var prioritizeMirroring = UserDefaults.standard.object(forKey: "prioritizeMirroring") as? Bool ?? true { didSet { UserDefaults.standard.set(prioritizeMirroring, forKey: "prioritizeMirroring"); sharing.updateUploadPacing() } }
    @Published private(set) var isAdjustingQuality = false
    @Published private(set) var session: ScrcpySession?
    @Published private(set) var activeDeviceID: String?
    @Published private(set) var hasRuntime = false
    @Published var recentlyPairedID: String?
    @Published var discoveryMessage: String?
    @Published var connectionMessage: String?
    @Published var isReconnecting = false
    @Published var isStartingMirror = false
    @Published private(set) var recoveryState: ConnectionRecoveryState = .idle
    let sharing = SessionSharingModel()

    var canPairCode: Bool { hasRuntime && !isPairing && PairingCode.normalized(pairingCode) != nil && (pairingServices.count == 1 || pairingServices.contains { $0.id == selectedPairingServiceID }) }
    var activeDevice: DeviceRecord? { devices.first { $0.id == activeDeviceID } }
    var onShowDevices: (() -> Void)?
    var onShowPairing: (() -> Void)?
    var onClosePairing: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onUISettingsChanged: (() -> Void)?
    var onStatusChanged: (() -> Void)?

    var tools: RuntimeTools?
    var adb: ADBClient?
    private var ownedADBServer: OwnedADBServer?
    private var runtimeTask: Task<Void, Never>?
    private var runtimeGeneration = UUID()
    private var runtimeRecoveryTask: Task<Void, Never>?
    private var runtimeRestartTimes: [TimeInterval] = []
    private var serviceGeneration = UUID()
    private var refreshGeneration = UUID()
    private let pairingLogger = Logger(subsystem: "com.nearby.pixelmirror", category: "Pairing")
    private let discovery = DeviceDiscovery()
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var manualConnectionTask: Task<Void, Never>?
    private var manualGeneration = UUID()
    private var pendingPairedHost: String?
    private var pendingPairedID: String?
    private var streamTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var qrExpiryTask: Task<Void, Never>?
    private var qrAttempt: QRPairingAttempt?
    private var pairingGeneration = UUID()
    var streamGeneration = UUID()
    private var pairingOpen = false
    private var connectionServices: [PairingService] = []
    private var endpointGeneration = UUID()
    private var serialIdentities: [String: String] = [:]
    private var bonjourError: String?
    private var shuttingDown = false
    private var hasStarted = false
    private var connectAttempts: [String: Date] = [:]
    private var blockedConnectionAddresses = Set<String>()
    private var existingAuthorizationScanRequested = false
    var mirrorWindow: MirrorWindowController?
    private var suppressLoginUpdate = true
    private var recovery = ConnectionRecovery()
    private var recoveryTaskGeneration = UUID()
    private var connectionStabilityTask: Task<Void, Never>?
    private var liveness = ConnectionLiveness()
    private var sessionTransportSerial: String?
    private var heartbeatTask: Task<Void, Never>?
    private var verifiedHealth: (target: ConnectionHealthTarget, time: TimeInterval)?
    private let videoQuality = VideoQualityCoordinator()
    private var startingQualityProfile: StreamQualityProfile?
    private var qualityRestartToken = UUID()
    private let networkMonitor = NWPathMonitor()
    private var networkIsAvailable = true
    private var receivedNetworkPath = false
    private var isSleeping = false
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: "devices.v1"), let saved = try? JSONDecoder().decode([DeviceRecord].self, from: data) {
            devices = saved.map { var d = $0; d.state = .unavailable; return d }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        suppressLoginUpdate = false
        videoQuality.onChange = { [weak self] in
            self?.objectWillChange.send()
            self?.sharing.updateUploadPacing()
        }
        videoQuality.applyProfile = { [weak self] profile, generation in
            await self?.applyStreamQuality(profile, generation: generation) ?? false
        }
        discovery.onChange = { [weak self] pairing, connection in
            guard let self else { return }
            pairingServices = pairing
            if connectionServices != connection { endpointGeneration = UUID(); invalidateRefresh() }
            connectionServices = connection
            if !pairing.isEmpty || !connection.isEmpty { bonjourError = nil }
            if !pairing.contains(where: { $0.id == selectedPairingServiceID }) { selectedPairingServiceID = pairing.first?.id ?? "" }
            handleQRDiscovery()
            refresh()
        }
        discovery.onError = { [weak self] message in self?.bonjourError = message; self?.discoveryMessage = message }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        observeConnectionEnvironment()
        discovery.start()
        startConnectionService()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }
    func startConnectionService() {
        guard !shuttingDown, runtimeTask == nil, adb == nil else { return }
        let attemptID = UUID(); runtimeGeneration = attemptID
        runtimeStatus = "Starting Android connection service…"
        pairingLogger.notice("Starting Nearby's Android connection service.")
        do {
            if ownedADBServer == nil {
                let runtime = try RuntimeTools.locate()
                tools = runtime
                let server = OwnedADBServer(adbURL: runtime.adbURL)
                server.onUnexpectedExit = { [weak self] detail in self?.connectionServiceDidExit(detail) }
                ownedADBServer = server
            }
        } catch {
            runtimeStatus = "Android tools could not be opened."
            pairingLogger.error("Android tools couldn't be loaded: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            return
        }
        guard let server = ownedADBServer else {
            runtimeStatus = "Android connection service is unavailable."
            errorMessage = "Nearby couldn't initialize its Android connection service."
            return
        }
        runtimeTask = Task { [weak self] in
            guard let self else { return }
            defer { if runtimeGeneration == attemptID { runtimeTask = nil } }
            do {
                let client = try await server.start()
                guard !Task.isCancelled, !shuttingDown, runtimeGeneration == attemptID else { return }
                adb = client; hasRuntime = true; runtimeStatus = nil
                connectAttempts.removeAll()
                if pairingOpen && pairingMode == .qr { refreshQR() }
                pairingLogger.notice("Nearby's own Android connection service is ready.")
                handleQRDiscovery(); refresh()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, runtimeGeneration == attemptID else { return }
                runtimeStatus = "Android connection service couldn't start."
                pairingLogger.error("Android connection service failed: \(error.localizedDescription, privacy: .public)")
                setError("Nearby couldn't start its Android connection service. " + error.localizedDescription)
            }
        }
    }
    private func connectionServiceDidExit(_ detail: String) {
        guard !shuttingDown else { return }
        pairingLogger.error("Android connection service stopped: \(detail, privacy: .public)")
        serviceGeneration = UUID(); refreshGeneration = UUID()
        runtimeGeneration = UUID()
        runtimeTask?.cancel(); runtimeTask = nil
        refreshTask?.cancel(); refreshTask = nil; isSearching = false
        adb = nil; hasRuntime = false
        invalidatePairing(); cancelManualConnection()
        if activeDeviceID != nil {
            interruptSession(message: "Restarting the Android connection service…", automatically: resumeSessions)
        }
        for index in devices.indices { devices[index].state = .unavailable }
        pairingDiagnostic = detail
        pairingStatus = "Android connection service stopped"
        let now = ProcessInfo.processInfo.systemUptime
        runtimeRestartTimes.removeAll { now - $0 > 60 }
        guard runtimeRestartTimes.count < 3 else {
            runtimeStatus = "Android connection service keeps stopping. Try Again to restart it."
            if activeDeviceID != nil { stopRecovery(message: "The Android connection service keeps stopping. Choose Try Again to restart it.") }
            onStatusChanged?()
            return
        }
        runtimeRestartTimes.append(now)
        runtimeStatus = "Restarting Android connection service…"
        runtimeRecoveryTask?.cancel()
        runtimeRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, !shuttingDown else { return }
            startConnectionService()
        }
        onStatusChanged?()
    }
    func shutdown() {
        shuttingDown = true
        networkMonitor.cancel()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceObservers.removeAll()
        runtimeTask?.cancel(); runtimeRecoveryTask?.cancel(); pollTask?.cancel(); refreshTask?.cancel(); closePairing(); disconnect(); discovery.stop()
    }
    func shutdownAndWait() async {
        let engine = session
        let heartbeat = heartbeatTask
        shutdown()
        await engine?.stopAndWait()
        await heartbeat?.value
        await sharing.stopAndWait()
        await ownedADBServer?.stopOwnServer()
    }
    func refresh() {
        guard !shuttingDown, refreshTask == nil, let adb else { return }
        isSearching = true
        let generation = serviceGeneration, refreshID = UUID()
        let probeExistingAuthorization = existingAuthorizationScanRequested
        existingAuthorizationScanRequested = false
        refreshGeneration = refreshID
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if refreshID == refreshGeneration {
                    isSearching = false; hasCompletedInitialDiscovery = true; refreshTask = nil
                    for i in devices.indices where devices[i].state == .searching && devices[i].id != pendingPairedID { devices[i].state = .unavailable }
                }
            }
            do {
                for service in connectionServices {
                    guard !Task.isCancelled, generation == serviceGeneration else { return }
                    // The retained mirror owns every connect probe for its
                    // target, including paused/exhausted states. Passive device
                    // refresh must not bypass the six-attempt recovery budget.
                    if let active = activeDevice, ConnectionEndpointMatcher.isTrusted(service, for: active) { continue }
                    let lastAttempt = connectAttempts[service.address]
                    let knownDevice = devices.contains { $0.isWireless && ConnectionEndpointMatcher.isTrusted(service, for: $0) }
                    // QR pairing must precede opening a connection to a new phone.
                    // The explicit Find Paired Devices action may probe an existing
                    // Mac authorization; failed transports wait for a user retry.
                    guard knownDevice || pendingPairedHost == service.host || probeExistingAuthorization,
                          !blockedConnectionAddresses.contains(service.address),
                          Date().timeIntervalSince(lastAttempt ?? .distantPast) > 15 else { continue }
                    connectAttempts[service.address] = Date()
                    blockedConnectionAddresses.insert(service.address)
                    if let response = try? await adb.checked(["connect", service.address], timeout: 4),
                       !Task.isCancelled, generation == serviceGeneration,
                       response.hasPrefix("connected to ") || response.hasPrefix("already connected to ") {
                        blockedConnectionAddresses.remove(service.address)
                    }
                }
                let output = try await adb.checked(["devices", "-l"], timeout: 8)
                guard !Task.isCancelled, generation == serviceGeneration else { return }
                let found = ADBDevice.parse(output)
                discoveryMessage = bonjourError
                var records = devices
                var seen = Set<String>()
                // Prefer wireless if the same hardware is also connected with USB.
                func transportRank(_ transport: ADBDevice) -> Int { transport.status == "device" ? (transport.isWireless ? 2 : 1) : 0 }
                for transport in found.sorted(by: { transportRank($0) < transportRank($1) }) {
                    var identity: String?
                    if transport.status == "device" {
                        if recoveryState == .connected, liveness.target?.serial == transport.serial {
                            // The bounded heartbeat owns this exact identity
                            // probe; reuse only its recent verified response.
                            identity = freshHeartbeatIdentity(serial: transport.serial)
                        } else {
                            let hardware = try? await adb.checked(["-s", transport.serial, "shell", "getprop", "ro.serialno"], timeout: 3)
                            guard !Task.isCancelled, generation == serviceGeneration else { return }
                            identity = hardware.flatMap { $0.isEmpty ? nil : $0 }
                        }
                    }
                    let verifiedHardware = identity != nil
                    identity = identity ?? serialIdentities[transport.serial]
                    let id = identity ?? transport.serial
                    if identity != nil { serialIdentities[transport.serial] = id }
                    seen.insert(id)
                    // Upgrade an initially unauthorized transport to its stable hardware identity.
                    if id != transport.serial, let fallback = records.firstIndex(where: { $0.id == transport.serial }) {
                        if records.contains(where: { $0.id == id }) { records.remove(at: fallback) }
                        else { records[fallback].id = id }
                    }
                    if let host = pendingPairedHost, transport.status == "device", transport.isWireless,
                       transport.serial.contains(host) || connectionServices.contains(where: { $0.host == host && transport.serial.contains($0.name) }) {
                        if let pendingPairedID { records.removeAll { $0.id == pendingPairedID } }
                        pendingPairedID = nil; pendingPairedHost = nil; recentlyPairedID = id
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(3))
                            if self?.recentlyPairedID == id { self?.recentlyPairedID = nil }
                        }
                    }
                    let state: DeviceState = transport.status == "device" && verifiedHardware ? .available : transport.status == "unauthorized" ? .unauthorized : .unavailable
                    let verifiedService = verifiedHardware ? connectionServices.first { ConnectionEndpointMatcher.serviceMatchesTransport($0, serial: transport.serial) }?.name : nil
                    if let index = records.firstIndex(where: { $0.id == id }) {
                        records[index].serial = transport.serial
                        records[index].isWireless = transport.isWireless
                        if let verifiedService { records[index].discoveryServiceName = verifiedService }
                        records[index].state = id == activeDeviceID && session?.isStreaming == true ? .mirroring : id == activeDeviceID && (isStartingMirror || isReconnecting || isAdjustingQuality) ? .connecting : state
                    } else {
                        records.append(DeviceRecord(id: id, serial: transport.serial, name: transport.model, state: state, isWireless: transport.isWireless, discoveryServiceName: verifiedService))
                    }
                }
                for i in records.indices where !seen.contains(records[i].id) {
                    if records[i].id != pendingPairedID && !(records[i].id == activeDeviceID && (session?.isStreaming == true || isStartingMirror || isReconnecting || isAdjustingQuality)) { records[i].state = .unavailable }
                }
                guard !Task.isCancelled, generation == serviceGeneration else { return }
                devices = records; persistDevices(); onStatusChanged?()
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, generation == serviceGeneration, refreshID == refreshGeneration {
                    discoveryMessage = error.localizedDescription
                }
            }
        }
    }

    func retryDiscovery() {
        connectAttempts.removeAll(); blockedConnectionAddresses.removeAll(); existingAuthorizationScanRequested = true
        for i in devices.indices where devices[i].state == .unavailable { devices[i].state = .searching }
        refresh()
    }
    func openPairing() {
        pairingOpen = true; pairingCode = ""; pairingError = nil; pairingDiagnostic = nil; pairingMode = .qr; refreshQR(); onShowPairing?()
    }
    func closePairing() {
        pairingOpen = false; invalidatePairing(); cancelManualConnection(); qrImage = nil; qrAttempt = nil; onClosePairing?()
    }
    private func invalidatePairing() {
        pairingGeneration = UUID(); pairingTask?.cancel(); pairingTask = nil; isPairing = false
        qrExpiryTask?.cancel(); qrExpiryTask = nil; qrAttempt = nil; qrImage = nil
    }
    func refreshQR() {
        invalidatePairing(); pairingError = nil; pairingDiagnostic = nil; pairingStatus = "Waiting for your Pixel…"
        guard hasRuntime else { pairingStatus = runtimeStatus ?? "Starting Android connection service…"; return }
        do {
            let attempt = try QRPairingAttempt(); qrAttempt = attempt
            let filter = CIFilter.qrCodeGenerator(); filter.message = Data(attempt.payload.utf8); filter.correctionLevel = "M"
            guard let image = filter.outputImage else { throw ADBError.command("Couldn't create a pairing code.") }
            let border = 4.0
            let extent = image.extent.insetBy(dx: -border, dy: -border)
            let white = CIImage(color: .white).cropped(to: extent)
            let final = image.composited(over: white).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            guard let cgImage = CIContext().createCGImage(final, from: final.extent) else { throw ADBError.command("Couldn't create a pairing code.") }
            qrImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            let generation = pairingGeneration
            qrExpiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                guard let self, !Task.isCancelled, generation == pairingGeneration, !isPairing else { return }
                qrAttempt = nil; qrImage = nil; pairingStatus = "Code expired"; pairingError = "Refresh the QR code and scan it again."
            }
            handleQRDiscovery()
        } catch { pairingError = error.localizedDescription }
    }
    private func handleQRDiscovery() {
        guard hasRuntime, pairingOpen, pairingMode == .qr, !isPairing, let attempt = qrAttempt,
              let service = pairingServices.first(where: { $0.name == attempt.serviceName }) else { return }
        pair(service: service, secret: attempt.secret)
    }
    func pairWithCode() {
        guard let code = PairingCode.normalized(pairingCode) else { pairingError = "Enter all six digits."; return }
        guard let service = pairingServices.first(where: { $0.id == selectedPairingServiceID }) ?? (pairingServices.count == 1 ? pairingServices.first : nil) else {
            pairingError = "Open Pair device with pairing code on your Pixel first."; return
        }
        pair(service: service, secret: code)
    }
    private func pair(service: PairingService, secret: String) {
        guard let adb, !isPairing else { return }
        let generation = pairingGeneration
        isPairing = true; pairingError = nil; pairingDiagnostic = nil; pairingStatus = "Pairing…"; qrExpiryTask?.cancel()
        pairingLogger.notice("The Pixel pairing service was discovered; starting secure pairing.")
        pairingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await adb.checked(["pair", service.address, secret], timeout: 20)
                guard !Task.isCancelled, generation == pairingGeneration else { return }
                guard output.localizedCaseInsensitiveContains("successfully paired") else { throw ADBError.command("Pairing didn't complete. Open a fresh code on your Pixel and try again.") }
                isPairing = false; pairingStatus = "Paired. Finding your Pixel…"
                recordPairingSuccess(host: service.host)
                // Connection advertisements use a different port and arrive after the pairing service closes.
                connectAttempts.removeAll(); refresh()
                closePairing(); showDevices()
            } catch is CancellationError { }
            catch {
                guard generation == pairingGeneration else { return }
                isPairing = false
                let failure = PairingFailure(error: error, secret: secret)
                pairingError = failure.message; pairingDiagnostic = failure.detail
                pairingLogger.error("Pairing failed: \(failure.detail, privacy: .public)")
                pairingStatus = "Pairing didn't finish"
                if pairingMode == .qr { qrAttempt = nil; qrImage = nil }
            }
        }
    }
    func connectManually(address: String, pairingCode: String?) {
        guard let adb else { return }
        do {
            let target = try ConnectionAddress(address)
            if let code = pairingCode {
                guard let code = PairingCode.normalized(code) else { pairingError = "Enter all six digits."; return }
                runManualPair(adb: adb, address: target.value, code: code)
            } else {
                cancelManualConnection(); let generation = manualGeneration
                isPairing = true; pairingError = nil
                manualConnectionTask = Task {
                    do {
                        let response = try await adb.checked(["connect", target.value], timeout: 12)
                        guard !Task.isCancelled, generation == manualGeneration else { return }
                        guard response.contains("connected to") || response.contains("already connected") else { throw ADBError.command(response) }
                        isPairing = false; showConnectionHelp = false; connectAttempts.removeAll(); refresh()
                    } catch {
                        guard !Task.isCancelled, generation == manualGeneration else { return }
                        isPairing = false; pairingError = error.localizedDescription
                    }
                }
            }
        } catch { pairingError = error.localizedDescription; setError(error.localizedDescription) }
    }
    func cancelManualConnection() {
        manualGeneration = UUID(); manualConnectionTask?.cancel(); manualConnectionTask = nil
        if isPairing { invalidatePairing() }
    }
    private func recordPairingSuccess(host: String) {
        blockedConnectionAddresses.removeAll()
        if let pendingPairedID { devices.removeAll { $0.id == pendingPairedID } }
        let id = "pending-" + UUID().uuidString
        pendingPairedHost = host; pendingPairedID = id
        devices.append(DeviceRecord(id: id, serial: "", name: "Your Pixel", state: .searching))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, pendingPairedID == id else { return }
            setState(id, .unavailable)
            discoveryMessage = "Paired. Keep Wireless debugging on while Nearby finds the connection."
        }
    }
    private func runManualPair(adb: ADBClient, address: String, code: String) {
        invalidatePairing(); let generation = pairingGeneration; isPairing = true; pairingStatus = "Pairing…"; pairingError = nil
        pairingTask = Task {
            do {
                let output = try await adb.checked(["pair", address, code], timeout: 20)
                guard !Task.isCancelled, generation == pairingGeneration else { return }
                guard output.localizedCaseInsensitiveContains("successfully paired") else { throw ADBError.command("Pairing didn't complete.") }
                isPairing = false
                let host = address.hasPrefix("[") ? String(address.dropFirst().prefix { $0 != "]" }) : String(address.prefix { $0 != ":" })
                recordPairingSuccess(host: host)
                showConnectionHelp = false; closePairing(); showDevices(); refresh()
            } catch {
                guard generation == pairingGeneration, !Task.isCancelled else { return }
                isPairing = false; pairingError = "Couldn't pair. Open a fresh pairing code and try again."
            }
        }
    }

    func mirror(_ device: DeviceRecord) {
        if activeDeviceID == device.id, session != nil {
            showMirror()
            if session?.isStreaming != true && !isAdjustingQuality { retryConnection() }
            return
        }
        guard [.available, .mirroring].contains(device.state), let tools, let adb else { return }
        let previousFrame = mirrorWindow?.window?.frame
        disconnect()
        activeDeviceID = device.id
        invalidateRefresh()
        streamGeneration = recovery.open(deviceID: device.id)
        let generation = streamGeneration
        videoQuality.open(generation: generation, ceiling: qualityCeiling, automatic: adaptiveQuality)
        syncRecoveryState(message: "Opening the Pixel display…")
        let engine = ScrcpySession(adb: adb, serverURL: tools.serverURL, serverVersion: tools.serverVersion)
        session = engine
        engine.onFirstFrame = { [weak self, weak engine] in
            guard let self, generation == streamGeneration, let engine, session === engine,
                  recovery.accepts(generation, deviceID: device.id) else { return }
            if isAdjustingQuality, recoveryState == .connected {
                isAdjustingQuality = false
                videoQuality.streamStarted(profile: startingQualityProfile ?? qualityCeiling)
                if let serial = sessionTransportSerial {
                    liveness.monitor(deviceID: device.id, generation: generation, serial: serial)
                    startConnectionHeartbeat(engine: engine)
                }
                observeStableConnection(engine: engine, generation: generation)
                if turnOffDisplay { engine.setScreenPower(false) }
                setState(device.id, .mirroring)
                sharing.resumeAfterVideoReconfiguration()
                onStatusChanged?()
                return
            }
            guard recoveryState == .connecting || recoveryState == .recovering else { return }
            recovery.connected(); syncRecoveryState(message: nil)
            videoQuality.streamStarted(profile: startingQualityProfile ?? qualityCeiling)
            if let serial = sessionTransportSerial {
                liveness.monitor(deviceID: device.id, generation: generation, serial: serial)
                startConnectionHeartbeat(engine: engine)
            }
            observeStableConnection(engine: engine, generation: generation)
            setState(device.id, .mirroring)
            if turnOffDisplay { engine.setScreenPower(false) }
            sessionBecameActive(engine: engine, generation: generation)
            onStatusChanged?()
        }
        configureSessionClipboard(engine: engine, generation: generation)
        engine.onPerformanceSample = { [weak self, weak engine] sample in
            guard let self, let engine, session === engine, generation == streamGeneration,
                  recoveryState == .connected, !isAdjustingQuality, engine.isStreaming else { return }
            videoQuality.receive(sample, generation: generation)
        }
        engine.onEnded = { [weak self] message in
            guard let self, generation == streamGeneration,
                  recovery.accepts(generation, deviceID: device.id) else { return }
            if retryTask != nil {
                // The current attempt may briefly decode then fail. Keep its
                // original six-attempt/90-second episode and let the same loop
                // continue; never cancel/reset the loop from its own callback.
                connectionStabilityTask?.cancel(); connectionStabilityTask = nil
                sessionBecameInactive(); session?.stop()
                recovery.interrupted(now: ProcessInfo.processInfo.systemUptime, automatically: resumeSessions)
                if recovery.state == .failed {
                    stopRecovery(message: "Recovery stopped after its retry limit. Check Wi-Fi and Wireless debugging, then choose Try Again.")
                    return
                }
                syncRecoveryState(message: resumeSessions ? "The connection was interrupted. Retrying the current recovery…" : "Recovery is paused. Choose Try Again when you’re ready.")
                return
            }
            interruptSession(message: "The connection was interrupted. Looking for your Pixel’s current address…", automatically: resumeSessions)
        }
        let controller = MirrorWindowController(model: self, session: engine, deviceName: device.name)
        controller.onUserClose = { [weak self] in self?.disconnect() }
        mirrorWindow = controller
        if let previousFrame { controller.window?.setFrame(previousFrame, display: false) }
        controller.show()
        streamTask = Task { [weak self, weak engine] in
            guard let self, let engine else { return }
            do { try await startEngine(engine, serial: device.serial, adb: adb, generation: generation) }
            catch {
                guard !Task.isCancelled, generation == streamGeneration, session === engine else { return }
                interruptSession(message: "The display could not open. Looking for your Pixel’s current address…", automatically: resumeSessions)
            }
        }
    }

    private var qualityCeiling: StreamQualityProfile {
        quality == "High Quality" ? .high : quality == "Lower Bandwidth" ? .efficient : .balanced
    }

    var activeQualityDescription: String? {
        guard let profile = videoQuality.currentProfile, activeDeviceID != nil else { return nil }
        return "\(profile.displayName) · up to \(profile.maxFPS) fps"
    }

    var uploadRateLimit: Int? {
        guard prioritizeMirroring else { return nil }
        switch videoQuality.profileForStart ?? qualityCeiling {
        case .high, .balanced: return 500_000
        case .efficient: return 250_000
        case .constrained: return 125_000
        }
    }

    private func qualityPreferencesChanged() {
        videoQuality.configure(ceiling: qualityCeiling, automatic: adaptiveQuality)
    }

    func pauseQualityForInterruption() {
        qualityRestartToken = UUID()
        isAdjustingQuality = false
        videoQuality.suspend()
    }

    /// Replaces only scrcpy's sockets/process. File SYNC streams keep their
    /// verified device binding on the existing ADB transport throughout.
    private func applyStreamQuality(_ profile: StreamQualityProfile, generation: UUID) async -> Bool {
        guard let engine = session, let adb, let serial = sessionTransportSerial,
              generation == streamGeneration, recoveryState == .connected, !shuttingDown, !isSleeping else { return false }
        let token = UUID(); qualityRestartToken = token
        func isCurrent() -> Bool {
            !Task.isCancelled && qualityRestartToken == token && generation == streamGeneration &&
                session === engine && recoveryState == .connected && !shuttingDown && !isSleeping
        }
        // A pending acknowledged paste is allowed to finish before we replace
        // the control channel; repeated settings still coalesce in the owner.
        while sharing.isSendingText || engine.isTouchActive {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            guard isCurrent() else { return false }
        }
        guard isCurrent() else { return false }
        isAdjustingQuality = true
        sharing.pauseForVideoReconfiguration()
        heartbeatTask?.cancel(); heartbeatTask = nil
        liveness.stop(); verifiedHealth = nil
        connectionStabilityTask?.cancel(); connectionStabilityTask = nil
        onStatusChanged?()
        defer {
            if qualityRestartToken == token {
                isAdjustingQuality = false
                onStatusChanged?()
            }
        }
        await engine.stopAndWait()
        guard isCurrent() else { return false }
        startingQualityProfile = profile
        do {
            try await engine.start(serial: serial, options: profile.streamOptions, using: adb)
            return isCurrent() && engine.isStreaming
        } catch {
            guard isCurrent() else { return false }
            interruptSession(message: "The display could not resume. Looking for your Pixel’s current address…", automatically: resumeSessions)
            return false
        }
    }

    private func startEngine(_ engine: ScrcpySession, serial: String, adb: ADBClient, generation: UUID, startupTimeout: TimeInterval = 15) async throws {
        guard !Task.isCancelled, generation == streamGeneration, session === engine else { throw CancellationError() }
        sessionTransportSerial = serial
        let profile = videoQuality.profileForStart ?? qualityCeiling
        startingQualityProfile = profile
        try await engine.start(serial: serial, options: profile.streamOptions, using: adb, startupTimeout: startupTimeout)
    }

    func retryConnection() {
        guard activeDeviceID != nil, session != nil, !shuttingDown else { return }
        if adb == nil { runtimeRestartTimes.removeAll(); startConnectionService() }
        interruptSession(message: "Looking for your Pixel’s current address…", automatically: true, resetBudget: true)
    }

    private func interruptSession(message: String, automatically: Bool, resetBudget: Bool = false) {
        guard activeDeviceID != nil, session != nil, !shuttingDown else { return }
        recoveryTaskGeneration = UUID(); retryTask?.cancel(); retryTask = nil
        streamTask?.cancel(); streamTask = nil
        connectionStabilityTask?.cancel(); connectionStabilityTask = nil
        sessionBecameInactive(); session?.stop()
        if resetBudget { recovery.recover(now: ProcessInfo.processInfo.systemUptime, automatically: automatically) }
        else { recovery.interrupted(now: ProcessInfo.processInfo.systemUptime, automatically: automatically) }
        if isSleeping && automatically { recovery.sleep() }
        let detail = recovery.state == .paused ? "Recovery is paused. Choose Try Again when you’re ready." :
            recovery.state == .failed ? "Recovery stopped after its retry limit. Check Wi-Fi and Wireless debugging, then choose Try Again." : message
        syncRecoveryState(message: detail)
        setState(activeDeviceID ?? "", [.recovering, .waitingForNetwork, .sleeping].contains(recovery.state) ? .connecting : .unavailable)
        if recovery.state == .recovering {
            restartDiscovery()
            runRecovery()
        }
    }

    private func runRecovery() {
        guard retryTask == nil, recovery.state == .recovering || recovery.state == .waitingForNetwork else { return }
        let token = recoveryTaskGeneration, generation = streamGeneration
        retryTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == recoveryTaskGeneration { retryTask = nil } }
            // Bonjour gets a fresh browse/resolve pass before the first probe.
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            while !Task.isCancelled, token == recoveryTaskGeneration, generation == streamGeneration,
                  let device = activeDevice, let engine = session {
                guard recovery.state == .recovering || recovery.state == .waitingForNetwork else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard recovery.remaining(now: now) > 0 else { break }
                guard recovery.attempts < ConnectionRecovery.maximumAttempts else { break }
                if !networkIsAvailable && device.isWireless {
                    recovery.waitForNetwork(now: now)
                    syncRecoveryState(message: "Waiting for a network connection. Recovery stops after 90 seconds.")
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    continue
                }
                recovery.networkAvailable(now: now)
                let delay = min(recovery.nextDelay, recovery.remaining(now: now))
                if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return } }
                guard !Task.isCancelled, token == recoveryTaskGeneration,
                      generation == streamGeneration else { return }
                guard recovery.beginAttempt(now: ProcessInfo.processInfo.systemUptime) else { break }
                syncRecoveryState(message: "Looking for your Pixel • Attempt \(recovery.attempts) of \(ConnectionRecovery.maximumAttempts)")
                guard let adb else { continue }
                do {
                    if let serial = try await recoveredTransport(for: device, adb: adb, token: token) {
                        guard !Task.isCancelled, token == recoveryTaskGeneration, generation == streamGeneration,
                              recovery.accepts(generation, deviceID: device.id) else { return }
                        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index].serial = serial }
                        syncRecoveryState(message: "Opening your Pixel display • Attempt \(recovery.attempts) of \(ConnectionRecovery.maximumAttempts)")
                        let remaining = recovery.remaining(now: ProcessInfo.processInfo.systemUptime)
                        guard remaining > 0 else { break }
                        try await startEngine(engine, serial: serial, adb: adb, generation: generation, startupTimeout: remaining)
                        guard !Task.isCancelled, token == recoveryTaskGeneration else { return }
                        if engine.isStreaming { persistDevices(); return }
                    }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, token == recoveryTaskGeneration else { return }
                    sessionBecameInactive(); engine.stop()
                }
                // Resolution may have timed out while the phone or Wi-Fi was
                // asleep. A new browse lets the next bounded probe discover a
                // changed port/address instead of retaining a failed endpoint.
                restartDiscovery()
            }
            guard !Task.isCancelled, token == recoveryTaskGeneration, generation == streamGeneration else { return }
            stopRecovery(message: "Couldn’t reconnect. Check Wi-Fi and Wireless debugging, then choose Try Again or Connection Help.")
        }
    }

    private func recoveredTransport(for device: DeviceRecord, adb: ADBClient, token: UUID) async throws -> String? {
        let endpoints = endpointGeneration
        func remaining() throws -> TimeInterval {
            guard !Task.isCancelled, token == recoveryTaskGeneration else { throw CancellationError() }
            guard endpoints == endpointGeneration else { throw RecoveryProbeInterruption.endpointsChanged }
            let seconds = recovery.remaining(now: ProcessInfo.processInfo.systemUptime)
            guard seconds > 0 else { throw ADBError.timedOut }
            return seconds
        }
        guard let result = try await ConnectionRecoveryProbe.find(device: device, services: connectionServices, adb: adb, remaining: remaining) else { return nil }
        _ = try remaining()
        serialIdentities[result.serial] = result.hardwareID
        if let serviceName = result.discoveryServiceName,
           let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index].discoveryServiceName = serviceName }
        return result.serial
    }

    private func stopRecovery(message: String) {
        invalidateRefresh()
        recoveryTaskGeneration = UUID(); retryTask?.cancel(); retryTask = nil
        streamTask?.cancel(); streamTask = nil
        connectionStabilityTask?.cancel(); connectionStabilityTask = nil
        sessionBecameInactive(); session?.stop()
        recovery.fail(); syncRecoveryState(message: message)
        if let id = activeDeviceID { setState(id, .unavailable) }
    }

    private func syncRecoveryState(message: String?) {
        recoveryState = recovery.state
        if recovery.state != .connected {
            heartbeatTask?.cancel(); heartbeatTask = nil
            liveness.stop(); verifiedHealth = nil; sessionTransportSerial = nil
        }
        isStartingMirror = recovery.state == .connecting
        isReconnecting = [.recovering, .waitingForNetwork, .sleeping].contains(recovery.state)
        connectionMessage = message
        onStatusChanged?()
    }

    private func startConnectionHeartbeat(engine: ScrcpySession) {
        heartbeatTask?.cancel(); verifiedHealth = nil
        guard let target = liveness.target, let adb else { return }
        heartbeatTask = Task { [weak self, weak engine] in
            while !Task.isCancelled {
                guard let self, let engine, heartbeatIsCurrent(target, engine: engine) else { return }
                do {
                    let result = try await ConnectionHealthProbe.check(target, adb: adb)
                    guard !Task.isCancelled, heartbeatIsCurrent(target, engine: engine) else { return }
                    verifiedHealth = result == .verified ? (target, ProcessInfo.processInfo.systemUptime) : nil
                    if liveness.record(result, for: target) {
                        interruptSession(message: "Your Pixel stopped responding. Looking for its current address…", automatically: resumeSessions)
                        return
                    }
                    try await Task.sleep(for: .seconds(4))
                } catch { return } // Cancelled/stale work neither fails nor resets health.
            }
        }
    }

    private func observeStableConnection(engine: ScrcpySession, generation: UUID) {
        connectionStabilityTask?.cancel()
        connectionStabilityTask = Task { [weak self, weak engine] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, generation == streamGeneration, let engine,
                  session === engine, engine.isStreaming, recoveryState == .connected else { return }
            recovery.connectionBecameStable()
        }
    }

    private func heartbeatIsCurrent(_ target: ConnectionHealthTarget, engine: ScrcpySession) -> Bool {
        !shuttingDown && !isSleeping && recoveryState == .connected &&
            activeDeviceID == target.deviceID && streamGeneration == target.generation &&
            sessionTransportSerial == target.serial && liveness.target == target &&
            session === engine && engine.isStreaming
    }

    private func freshHeartbeatIdentity(serial: String) -> String? {
        guard let verifiedHealth, verifiedHealth.target == liveness.target,
              verifiedHealth.target.serial == serial, recoveryState == .connected,
              activeDeviceID == verifiedHealth.target.deviceID,
              streamGeneration == verifiedHealth.target.generation,
              ProcessInfo.processInfo.systemUptime - verifiedHealth.time <= 8 else { return nil }
        return verifiedHealth.target.deviceID
    }

    func cancelConnection() {
        guard activeDeviceID != nil else { return }
        invalidateRefresh()
        recoveryTaskGeneration = UUID(); retryTask?.cancel(); retryTask = nil
        streamTask?.cancel(); streamTask = nil
        connectionStabilityTask?.cancel(); connectionStabilityTask = nil
        sessionBecameInactive(); session?.stop()
        recovery.pause(); syncRecoveryState(message: "Recovery is paused. Choose Try Again when you’re ready.")
        if let id = activeDeviceID { setState(id, .unavailable) }
    }

    func disconnect() {
        recovery.close(); recoveryTaskGeneration = UUID()
        connectionStabilityTask?.cancel(); connectionStabilityTask = nil
        streamGeneration = UUID(); streamTask?.cancel(); streamTask = nil; retryTask?.cancel(); retryTask = nil
        sessionBecameInactive()
        videoQuality.close(); startingQualityProfile = nil
        let id = activeDeviceID; activeDeviceID = nil
        session?.stop(); session = nil
        mirrorWindow?.onUserClose = nil; mirrorWindow?.closeMirror(); mirrorWindow = nil
        syncRecoveryState(message: nil)
        if let id { setState(id, .unavailable) }
        refresh(); onStatusChanged?()
    }

    private func observeConnectionEnvironment() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.systemWillSleep() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.systemDidWake() }
        })
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkPathChanged(available: available) }
        }
        networkMonitor.start(queue: DispatchQueue(label: "com.nearby.connection-path"))
    }

    private func invalidateRefresh() {
        refreshGeneration = UUID(); refreshTask?.cancel(); refreshTask = nil; isSearching = false
    }

    private func restartDiscovery() {
        endpointGeneration = UUID()
        invalidateRefresh()
        connectAttempts.removeAll(); blockedConnectionAddresses.removeAll()
        discovery.restart()
    }

    private func systemWillSleep() {
        isSleeping = true
        guard activeDeviceID != nil, [.connecting, .connected, .recovering, .waitingForNetwork].contains(recovery.state) else { return }
        recoveryTaskGeneration = UUID(); retryTask?.cancel(); retryTask = nil
        streamTask?.cancel(); streamTask = nil
        connectionStabilityTask?.cancel(); connectionStabilityTask = nil
        sessionBecameInactive(); session?.stop()
        recovery.sleep(); syncRecoveryState(message: "Mac is sleeping. Your display will reconnect after wake.")
    }

    private func systemDidWake() {
        isSleeping = false
        guard !shuttingDown else { return }
        restartDiscovery(); refresh()
        guard recovery.state == .sleeping else { return }
        recovery.wake(now: ProcessInfo.processInfo.systemUptime, automatically: resumeSessions)
        syncRecoveryState(message: resumeSessions ? "Mac woke up. Looking for your Pixel’s current address…" : "Recovery is paused. Choose Try Again when you’re ready.")
        if recovery.state == .recovering { runRecovery() }
    }

    private func networkPathChanged(available: Bool) {
        let wasAvailable = networkIsAvailable
        networkIsAvailable = available
        let firstPath = !receivedNetworkPath; receivedNetworkPath = true
        guard !shuttingDown, !firstPath, !isSleeping else { return }
        // This monitor describes the Mac's available paths, not the Pixel's
        // active transport. A satisfied-to-satisfied update can concern DNS,
        // policy or another interface. Refresh Bonjour, but let the bounded
        // identity heartbeat decide whether the existing stream needs recovery.
        restartDiscovery(); refresh()
        guard let device = activeDevice, device.isWireless else { return }
        if !available && wasAvailable && [.connecting, .connected].contains(recovery.state) {
            interruptSession(message: "Network connection lost. Waiting for Wi-Fi…", automatically: resumeSessions)
        } else if available && recovery.state == .waitingForNetwork {
            recovery.networkAvailable(now: ProcessInfo.processInfo.systemUptime)
            syncRecoveryState(message: "Network restored. Looking for your Pixel’s current address…")
        }
    }
    func showMirror() { mirrorWindow?.show() }
    func showMirrorControls() { mirrorWindow?.revealControls() }
    func fitMirror() { mirrorWindow?.fitToScreen() }
    func showDevices() { onShowDevices?(); refresh() }
    func showSettings() { onShowSettings?() }
    func setError(_ message: String) { errorMessage = message }
    private func setState(_ id: String, _ state: DeviceState) { if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].state = state } }
    private func persistDevices() { if let data = try? JSONEncoder().encode(devices.filter { !$0.id.hasPrefix("pending-") }) { UserDefaults.standard.set(data, forKey: "devices.v1") } }

    func changeImage(_ device: DeviceRecord) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a wallpaper or image for \(device.name)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey]); guard (attributes.fileSize ?? 0) < 30_000_000 else { throw ADBError.command("Choose an image smaller than 30 MB.") }
            guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw ADBError.command("This image couldn't be opened.") }
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Nearby/DeviceImages")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(UUID().uuidString + ".png"); try png.write(to: destination, options: .atomic)
            if let i = devices.firstIndex(where: { $0.id == device.id }) { deleteImage(devices[i].imagePath); devices[i].imagePath = destination.path; persistDevices() }
        } catch { setError(error.localizedDescription) }
    }
    func resetImage(_ device: DeviceRecord) { if let i = devices.firstIndex(where: { $0.id == device.id }) { deleteImage(devices[i].imagePath); devices[i].imagePath = nil; persistDevices() } }
    private func deleteImage(_ path: String?) {
        guard let path, path.contains("/Nearby/DeviceImages/") else { return }; try? FileManager.default.removeItem(atPath: path)
    }
    func rename(_ device: DeviceRecord) {
        let alert = NSAlert(); alert.messageText = "Rename Device"; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: device.name); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i].name = String(name.prefix(80)); persistDevices() }
    }
    func forget(_ device: DeviceRecord) {
        let alert = NSAlert(); alert.messageText = "Remove \(device.name) from Nearby?"; alert.informativeText = "To revoke this Mac's debugging access, also remove it in Wireless debugging → Paired devices on your Pixel."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if activeDeviceID == device.id { disconnect() }; deleteImage(device.imagePath); devices.removeAll { $0.id == device.id }; persistDevices()
    }
    func takeScreenshot() {
        guard let image = session?.screenshot() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Pixel Screenshot.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        do { guard let png = rep.representation(using: .png, properties: [:]) else { return }; try png.write(to: url, options: .atomic) } catch { setError(error.localizedDescription) }
    }
    private func updateLoginItem() {
        guard !suppressLoginUpdate else { return }
        do { if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { suppressLoginUpdate = true; launchAtLogin = SMAppService.mainApp.status == .enabled; suppressLoginUpdate = false; setError(error.localizedDescription) }
    }
}

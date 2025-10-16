import SwiftUI
import NearbyCore

struct PairingView: View {
    @ObservedObject var model: AppModel
    @State private var showManual = false
    @State private var manualPairing = false
    @State private var address = ""
    @State private var manualCode = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(spacing: 22) {
            Picker("Pairing method", selection: $model.pairingMode) {
                Text("Scan QR").tag(PairingMode.qr)
                Text("Enter Code").tag(PairingMode.code)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 228)
            .disabled(model.isPairing)

            if model.pairingMode == .qr { qrBody } else { codeBody }

            if let error = model.pairingError {
                InlineMessage(text: error, isError: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let diagnostic = model.pairingDiagnostic {
                DisclosureGroup("Connection Details") {
                    Text(diagnostic).font(NearbyStyle.captionFont).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(NearbyStyle.captionFont)
            }
            DisclosureGroup("Device not found?", isExpanded: $showManual) {
                manualHelp
            }
            .font(NearbyStyle.captionFont)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Find Paired Devices") {
                    model.retryDiscovery()
                    model.showDevices()
                    model.closePairing()
                }
                .buttonStyle(.link)
                .disabled(!model.hasRuntime)
                Spacer()
                Button("Cancel", action: model.closePairing)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                if model.pairingMode == .code {
                    Button(model.isPairing ? "Pairing…" : "Pair", action: model.pairWithCode)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canPairCode || model.isPairing)
                }
            }
        }
        .font(NearbyStyle.bodyFont)
        .buttonBorderShape(.capsule)
        .padding(28)
        .frame(width: NearbyStyle.pairingWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showDeveloperHelp) { developerHelp }
        .onChange(of: model.pairingMode) { _, mode in
            codeFocused = mode == .code
        }
    }

    private var qrBody: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 12) {
                Group {
                    if !model.hasRuntime {
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 30))
                            Text("Pairing Unavailable").font(NearbyStyle.captionFont)
                        }.foregroundStyle(.black.opacity(0.6)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let image = model.qrImage {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(16)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "qrcode").font(.system(size: 36))
                            Text("Refresh to scan again").font(NearbyStyle.captionFont)
                        }.foregroundStyle(.black.opacity(0.6)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 214, height: 214)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(qrAccessibilityLabel)
                HStack(spacing: 6) {
                    if model.hasRuntime && (model.qrImage != nil || model.isPairing) { ProgressView().controlSize(.mini) }
                    Text(model.hasRuntime ? (model.pairingStatus.isEmpty ? "Waiting for your phone…" : model.pairingStatus) : serviceStatus)
                }
                .font(NearbyStyle.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if model.hasRuntime {
                    Button("Refresh QR Code", action: model.refreshQR)
                        .buttonStyle(.link)
                        .font(NearbyStyle.captionFont)
                        .disabled(model.isPairing)
                } else {
                    Button("Try Again", action: model.startConnectionService)
                        .buttonStyle(.link)
                        .font(NearbyStyle.captionFont)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Pair your Android phone").font(NearbyStyle.titleFont)
                VStack(alignment: .leading, spacing: 5) {
                    Text("1. Open Wireless debugging.")
                    Text("Settings → System → Developer options")
                        .font(NearbyStyle.captionFont)
                        .foregroundStyle(.secondary)
                }
                Text("2. Tap Pair device with QR code.")
                Text("3. Scan the code on this Mac.")
                Button("Developer options missing?") { model.showDeveloperHelp = true }
                    .buttonStyle(.link)
                    .font(NearbyStyle.captionFont)
                Text("Keep both devices on the same Wi-Fi.")
                    .font(NearbyStyle.captionFont)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var codeBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter the code from your phone").font(NearbyStyle.titleFont)
            Text("In Wireless debugging, tap Pair device with pairing code.")
            if !model.hasRuntime {
                HStack {
                    InlineMessage(text: serviceStatus)
                    Button("Try Again", action: model.startConnectionService).buttonStyle(.link)
                }
            } else if model.pairingServices.count > 1 {
                Picker("Device", selection: $model.selectedPairingServiceID) {
                    Text("Choose a device").tag("")
                    ForEach(model.pairingServices) { service in
                        Text("\(service.name) · \(service.address)").tag(service.id)
                    }
                }
                .disabled(model.isPairing)
            } else if let service = model.pairingServices.first {
                Label(service.name, systemImage: "checkmark.circle")
                    .font(NearbyStyle.captionFont)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking for the pairing-code screen…")
                        .font(NearbyStyle.captionFont)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Pairing code")
                TextField("Six-digit code", text: $model.pairingCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 21, design: .monospaced))
                    .focused($codeFocused)
                    .disabled(model.isPairing || !model.hasRuntime)
                    .onSubmit { if model.canPairCode && !model.isPairing { model.pairWithCode() } }
                Text("Keep the pairing-code screen open on your phone.")
                    .font(NearbyStyle.captionFont)
                    .foregroundStyle(.secondary)
            }
            Button("Developer options missing?") { model.showDeveloperHelp = true }
                .buttonStyle(.link)
                .font(NearbyStyle.captionFont)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var manualHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use the same Wi-Fi network. Guest networks or a VPN can prevent discovery.")
                .foregroundStyle(.secondary)
            Toggle("Pair a new device manually", isOn: $manualPairing)
                .toggleStyle(.checkbox)
            TextField(manualPairing ? "Pairing address, for example 192.168.1.42:37123" : "Connection address, for example 192.168.1.42:40125", text: $address)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(manualPairing ? "Pairing IP address and port" : "Connection IP address and port")
            if manualPairing {
                TextField("Six-digit pairing code", text: $manualCode)
                    .textFieldStyle(.roundedBorder)
                Text("Use the IP address and port from the pairing-code dialog.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Use IP address & Port from the main Wireless debugging screen.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(manualPairing ? "Pair Manually" : "Connect") {
                    model.connectManually(address: address, pairingCode: manualPairing ? manualCode : nil)
                }
                .buttonStyle(.glass)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isPairing)
            }
        }
        .padding(.top, 10)
        .disabled(model.isPairing || !model.hasRuntime)
    }

    private var serviceStatus: String {
        model.runtimeStatus ?? "Android connection service is unavailable. Try again to resume pairing."
    }

    private var qrAccessibilityLabel: String {
        guard model.hasRuntime else { return "Pairing unavailable. " + serviceStatus }
        guard model.qrImage != nil else { return "No active QR code. Refresh to scan again, or choose Enter Code." }
        return "Pairing QR code. Scan using Android Wireless debugging, or choose Enter Code."
    }

    private var developerHelp: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("One-time setup on your phone").font(NearbyStyle.titleFont)
            Text("1. Open Settings → About phone.\n2. Tap Build number seven times. Unlock if asked.\n3. Go to System → Developer options.\n4. Turn on Wireless debugging.")
                .lineSpacing(7)
            Text("Some Android phones use different names for these settings.")
                .foregroundStyle(.secondary)
                .font(NearbyStyle.captionFont)
            HStack {
                Spacer()
                Button("Done") { model.showDeveloperHelp = false }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(NearbyStyle.bodyFont)
        .buttonBorderShape(.capsule)
        .padding(28)
        .frame(width: 500)
    }
}

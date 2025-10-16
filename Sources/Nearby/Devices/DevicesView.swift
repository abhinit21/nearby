import SwiftUI
import NearbyCore

struct DevicesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.devices.isEmpty {
                emptyState
            } else {
                Text("Paired Devices")
                    .font(NearbyStyle.captionFont)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.devices) { device in
                            deviceRow(device)
                        }
                    }
                }
                .frame(height: min(CGFloat(model.devices.count) * 152 - 12, 444))
                if let error = model.errorMessage { InlineMessage(text: error, isError: true) }
            }
            if model.hasRuntime, let message = model.discoveryMessage { InlineMessage(text: message) }
            if !model.hasRuntime {
                HStack {
                    InlineMessage(text: model.runtimeStatus ?? "Android connection service is unavailable.")
                    Button("Try Again", action: model.startConnectionService).buttonStyle(.link)
                }
            } else if let status = model.runtimeStatus {
                InlineMessage(text: status)
            }
        }
        .font(NearbyStyle.bodyFont)
        .buttonBorderShape(.capsule)
        .padding(20)
        .frame(width: NearbyStyle.devicesWidth, alignment: .topLeading)
        .frame(minHeight: 242, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showConnectionHelp) {
            ConnectionHelpView(model: model).onDisappear { model.cancelManualConnection() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.portrait")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.hasRuntime && !model.hasCompletedInitialDiscovery && model.isSearching ? "Looking for Devices" : "No Paired Devices")
                .font(NearbyStyle.titleFont)
            Text(!model.hasRuntime ? "Pairing will be available when the connection service is ready." : (!model.hasCompletedInitialDiscovery && model.isSearching ? "Previously authorized devices will appear here." : "Pair your Android phone to get started."))
                .foregroundStyle(.secondary)
            if model.hasRuntime && !model.hasCompletedInitialDiscovery && model.isSearching {
                ProgressView().controlSize(.small)
            }
            Button("Pair Device…", action: model.openPairing)
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
                .disabled(!model.hasRuntime)
            if let error = model.errorMessage {
                InlineMessage(text: error, isError: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func deviceRow(_ device: DeviceRecord) -> some View {
        HStack(spacing: 18) {
            DeviceArtwork(imagePath: device.imagePath)
            VStack(alignment: .leading, spacing: 5) {
                Text(device.name).fontWeight(.semibold).lineLimit(2)
                HStack(spacing: 5) {
                    if model.hasRuntime && (device.state == .searching || device.state == .connecting) {
                        ProgressView().controlSize(.mini).scaleEffect(0.8)
                    }
                    Text(!model.hasRuntime && device.state != .mirroring ? "Connection Service Unavailable" : (model.recentlyPairedID == device.id && device.state == .available ? "Paired · Available" : device.state.displayLabel))
                        .font(NearbyStyle.captionFont)
                        .foregroundStyle(.secondary)
                }
                if device.state == .unavailable || device.state == .unauthorized {
                    Button("Connection Help") { model.showConnectionHelp = true }
                        .buttonStyle(.link)
                        .font(NearbyStyle.captionFont)
                }
            }
            Spacer(minLength: 6)
            rowAction(device)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 140)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            Button("Rename…") { model.rename(device) }
            Button("Change Device Image…") { model.changeImage(device) }
            Button("Reset Device Image") { model.resetImage(device) }.disabled(device.imagePath == nil)
            Divider()
            Button("Forget Device…", role: .destructive) { model.forget(device) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(device.name)
    }

    @ViewBuilder
    private func rowAction(_ device: DeviceRecord) -> some View {
        switch device.state {
        case .available:
            Button("Mirror") { model.mirror(device) }
                .buttonStyle(.glassProminent)
                .disabled(!model.hasRuntime)
        case .mirroring:
            Button("Show Mirror", action: model.showMirror)
                .buttonStyle(.glassProminent)
        case .connecting:
            Button("Cancel", action: model.cancelConnection)
                .buttonStyle(.glass)
        case .unavailable, .unauthorized:
            Button("Try Again", action: model.retryDiscovery)
                .buttonStyle(.glass)
                .disabled(model.isSearching || !model.hasRuntime)
        case .searching:
            Button("Mirror") {}
                .buttonStyle(.glass)
                .disabled(true)
        }
    }
}

struct ConnectionHelpView: View {
    @ObservedObject var model: AppModel
    @State private var advanced = false
    @State private var showDeveloperHelp = false
    @State private var connectionAddress = ""
    @State private var pairingAddress = ""
    @State private var pairingCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connection Help").font(NearbyStyle.titleFont)
            Text("Keep your phone and Mac on the same Wi-Fi, and check that Wireless debugging is still on.")
            Text("Guest networks and VPNs may prevent device discovery. A saved device can reconnect without pairing again.")
                .foregroundStyle(.secondary)
            if !model.hasRuntime {
                InlineMessage(text: model.runtimeStatus ?? "Android connection service is unavailable. Try again to reconnect.")
            }
            DisclosureGroup("Advanced Connection Options", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect a paired device").fontWeight(.semibold)
                        TextField("Connection IP address and port", text: $connectionAddress)
                            .textFieldStyle(.roundedBorder)
                        Text("Use IP address & Port from the main Wireless debugging screen.")
                            .font(NearbyStyle.captionFont).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Connect") {
                                model.connectManually(address: connectionAddress, pairingCode: nil)
                            }
                            .buttonStyle(.glass)
                            .disabled(connectionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isPairing)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pair a new device").fontWeight(.semibold)
                        TextField("Pairing IP address and port", text: $pairingAddress)
                            .textFieldStyle(.roundedBorder)
                        TextField("Six-digit pairing code", text: $pairingCode)
                            .textFieldStyle(.roundedBorder)
                        Text("Use the temporary IP address, pairing port and code from Pair device with pairing code. This port is different from the connection port above.")
                            .font(NearbyStyle.captionFont).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button(model.isPairing ? "Pairing…" : "Pair Manually") {
                                model.connectManually(address: pairingAddress, pairingCode: pairingCode)
                            }
                            .buttonStyle(.glass)
                            .disabled(pairingAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pairingCode.filter(\.isNumber).count != 6 || model.isPairing)
                        }
                    }
                }
                .padding(.top, 12)
                .disabled(!model.hasRuntime || model.isPairing)
            }
            if let error = model.pairingError ?? model.errorMessage {
                InlineMessage(text: error, isError: true)
            }
            HStack {
                Button("Developer Options Help") { showDeveloperHelp = true }
                    .buttonStyle(.link)
                Spacer()
                Button("Done") { model.showConnectionHelp = false }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") {
                    if model.hasRuntime {
                        model.refresh()
                        model.showConnectionHelp = false
                    } else {
                        model.startConnectionService()
                    }
                }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(NearbyStyle.bodyFont)
        .buttonBorderShape(.capsule)
        .padding(28)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showDeveloperHelp) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Enable Wireless Debugging").font(NearbyStyle.titleFont)
                Text("1. Open Settings → About phone.\n2. Tap Build number seven times.\n3. Open System → Developer options.\n4. Turn on Wireless debugging.").lineSpacing(6)
                HStack {
                    Spacer()
                    Button("Done") { showDeveloperHelp = false }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .font(NearbyStyle.bodyFont).padding(28).frame(width: 460)
        }
    }
}

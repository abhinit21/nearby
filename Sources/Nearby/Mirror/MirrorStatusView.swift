import SwiftUI
import NearbyCore

struct MirrorStatusView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: ScrcpySession
    @State private var hasStreamed = false
    var body: some View {
        VStack(spacing: 14) {
            if model.isAdjustingQuality {
                ProgressView()
                Text("Adjusting video quality…").font(NearbyStyle.titleFont)
                Text("The display will resume shortly.")
                    .font(NearbyStyle.bodyFont).multilineTextAlignment(.center)
            } else if model.isReconnecting {
                ProgressView()
                Text(model.recoveryState == .waitingForNetwork ? "Waiting for Network" : model.recoveryState == .sleeping ? "Mac is Sleeping" : "Reconnecting…").font(NearbyStyle.titleFont)
                Text(model.connectionMessage ?? "Looking for your Pixel’s current address…")
                    .font(NearbyStyle.bodyFont).multilineTextAlignment(.center)
                Button("Cancel Recovery", action: model.cancelConnection).buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            } else if !model.isStartingMirror && (hasStreamed || model.connectionMessage != nil || model.errorMessage != nil || model.activeDevice?.state == .unavailable) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 24))
                Text(model.recoveryState == .failed ? "Connection Lost" : "Recovery Paused").font(NearbyStyle.titleFont)
                Text(model.connectionMessage ?? model.errorMessage ?? "Check Wi-Fi and Wireless debugging, then try again.")
                    .font(NearbyStyle.bodyFont).multilineTextAlignment(.center)
                if model.activeDevice != nil {
                    Button("Try Again", action: model.retryConnection).buttonStyle(.glassProminent)
                }
            } else {
                ProgressView()
                Text("Connecting…").font(NearbyStyle.bodyFont)
                Button("Cancel", action: model.cancelConnection).buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
            Button("Connection Help") { model.showDevices(); model.showConnectionHelp = true }
                .buttonStyle(.link)
            Button("Back to Devices") { model.disconnect(); model.showDevices() }
                .buttonStyle(.glass)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: session.isStreaming, initial: true) { _, streaming in
            if streaming { hasStreamed = true }
        }
    }
}

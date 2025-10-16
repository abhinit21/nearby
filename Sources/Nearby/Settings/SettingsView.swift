import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show Nearby in menu bar", isOn: $model.showMenuBar)
                Toggle("Open at login", isOn: $model.launchAtLogin)
                Toggle("Resume interrupted sessions", isOn: $model.resumeSessions)
                    .help("Recover after wake or network interruption. Closing or disconnecting a mirror always ends recovery.")
            }
            Section {
                Toggle("Play audio on Mac", isOn: $model.playAudio)
                    .disabled(true)
                    .help("Audio playback is not available in this build.")
                Toggle("Share text clipboard", isOn: $model.shareClipboard)
                    .help("Share text only while the Pixel mirror or its controls are active. Clipboard & Files shows status.")
                Toggle("Turn off phone display", isOn: $model.turnOffDisplay)
                Toggle("Automatically adjust video quality", isOn: $model.adaptiveQuality)
                    .help("Lower quality when video falls behind, then cautiously return to your chosen maximum after stable video.")
                Picker(model.adaptiveQuality ? "Maximum video quality" : "Video quality", selection: $model.quality) {
                    Text("Balanced").tag("Balanced")
                    Text("High Quality").tag("High Quality")
                    Text("Lower Bandwidth").tag("Lower Bandwidth")
                }
                if let quality = model.activeQualityDescription {
                    LabeledContent("Current session", value: quality)
                        .foregroundStyle(.secondary)
                }
                Toggle("Prioritize mirror during file transfers", isOn: $model.prioritizeMirroring)
                    .help("Pace uploads to leave room for responsive video and input. Turn off for unrestricted file-transfer speed.")
            } header: {
                Text("Mirroring")
            } footer: {
                Text("Quality changes briefly restart video while files continue sending. Lower Bandwidth uses up to 30 fps. Audio playback is not available in this build.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .font(NearbyStyle.bodyFont)
        .frame(width: NearbyStyle.settingsWidth)
        .frame(minHeight: 550)
    }
}

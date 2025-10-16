import AppKit
import SwiftUI

enum NearbyStyle {
    static let devicesWidth: CGFloat = 500
    static let pairingWidth: CGFloat = 620
    static let settingsWidth: CGFloat = 540
    static let bodyFont = Font.system(size: 13)
    static let captionFont = Font.system(size: 12)
    static let titleFont = Font.system(size: 17, weight: .semibold)
}

/// A selected image is a local identity preference, never an inferred wallpaper.
struct DeviceArtwork: View {
    let imagePath: String?
    var width: CGFloat = 52
    var height: CGFloat = 116

    private var image: NSImage? {
        imagePath.flatMap { NSImage(contentsOfFile: $0) }
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: "rectangle.portrait")
                    .font(.system(size: 29, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: width, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

struct InlineMessage: View {
    let text: String
    var isError = false

    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle" : "info.circle")
            .font(NearbyStyle.captionFont)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

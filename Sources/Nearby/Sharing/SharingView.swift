import AppKit
import SwiftUI
import NearbyCore

struct SharingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sharing: SessionSharingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Share Text Clipboard", isOn: $model.shareClipboard)
                .toggleStyle(.switch)
            Label(sharing.clipboardDescription, systemImage: statusIcon)
                .foregroundStyle(isClipboardFailure ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            HStack {
                Button("Paste to Pixel", action: sharing.pasteToPixel)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(!sharing.canSend || sharing.clipboardStatus == .sending)
                Text("⇧⌘V").foregroundStyle(.secondary).accessibilityHidden(true)
                Spacer()
                if isClipboardFailure || sharing.pasteFailed {
                    Button("Retry", action: sharing.retryClipboard).buttonStyle(.link)
                }
            }
            Text(sharing.pasteMessage ?? "Choose a text field on Pixel first. Explicit paste works when sharing is off.")
                .font(NearbyStyle.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            FileDropTarget(canAccept: sharing.canSend, onFiles: sharing.acceptFiles)
                .frame(height: 92)
                .accessibilityLabel("Drop files to Pixel Downloads")
            HStack {
                Button("Choose Files…", action: sharing.chooseFiles).disabled(!sharing.canSend)
                Spacer()
                Text("Existing files are kept.").font(NearbyStyle.captionFont).foregroundStyle(.secondary)
            }
            if let message = sharing.dropMessage { InlineMessage(text: message, isError: true) }
            if let coordinator = sharing.transfers {
                TransferList(coordinator: coordinator, canSend: sharing.canSend)
            } else {
                Text("Connect to Pixel to send files to Downloads.").foregroundStyle(.secondary)
            }
        }
        .font(NearbyStyle.bodyFont)
        .buttonBorderShape(.capsule)
        .padding(24)
        .frame(minWidth: 424, maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { sharing.refreshContext() }
    }

    private var isClipboardFailure: Bool {
        if case .failed = sharing.clipboardStatus { return true }; return false
    }
    private var statusIcon: String {
        switch sharing.clipboardStatus {
        case .ready: "checkmark.circle"
        case .sending: "arrow.up.circle"
        case .failed: "exclamationmark.circle"
        case .disabled: "clipboard"
        case .unavailable, .paused: "pause.circle"
        }
    }
}

private struct TransferList: View {
    @ObservedObject var coordinator: FileTransferCoordinator
    let canSend: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if coordinator.items.isEmpty {
                Text("No files sent yet. Drop regular files from Finder.")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Files to Downloads").fontWeight(.semibold)
                    Spacer()
                    if coordinator.isRunning {
                        Button(coordinator.isCancelling ? "Cancelling…" : "Cancel Transfers", action: coordinator.cancel)
                            .keyboardShortcut(.cancelAction)
                            .disabled(coordinator.isCancelling)
                    } else {
                        Button("Clear Finished", action: coordinator.dismissFinished).buttonStyle(.link)
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(coordinator.items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "doc").frame(width: 20).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.destinationName ?? item.name)
                                        .lineLimit(2).textSelection(.enabled)
                                        .help(item.destinationName ?? item.name)
                                    if [.preparing, .transferring, .finalizing].contains(item.state) {
                                        if item.state == .transferring {
                                            ProgressView(value: item.progress)
                                                .accessibilityLabel("Sending \(item.name)")
                                        } else { ProgressView().controlSize(.small) }
                                    }
                                    Text(detail(item)).font(NearbyStyle.captionFont)
                                        .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Group {
                                    if item.state == .failed || item.state == .cancelled {
                                        Button("Retry") { coordinator.retry(item.id) }
                                            .buttonStyle(.link).disabled(!canSend || coordinator.isRunning)
                                    } else if item.state == .completed {
                                        Image(systemName: "checkmark.circle").accessibilityLabel("Completed")
                                    }
                                }.frame(width: 48, alignment: .trailing)
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }.padding(.vertical, 4)
                }.frame(minHeight: 72, maxHeight: 230)
            }
            if coordinator.cleanupPending {
                InlineMessage(text: "Cleanup pending. Nearby removes only its own incomplete files when this Pixel reconnects.")
            }
        }
    }

    private func detail(_ item: FileTransferItem) -> String {
        switch item.state {
        case .queued: "Waiting…"
        case .preparing: "Preparing…"
        case .transferring: "Sending · \(ByteCountFormatter.string(fromByteCount: Int64(item.completedBytes), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))"
        case .finalizing: "Saving in Downloads…"
        case .completed: item.destinationName == item.name ? "Saved in Downloads" : "Saved in Downloads · renamed to keep both"
        case .cancelling: "Cancelling… completed files are kept."
        case .cancelled: "Cancelled · completed files are kept."
        case .failed: item.errorMessage ?? "Couldn’t send this file. Reconnect and retry."
        }
    }
}

@MainActor
enum FinderFiles {
    static func read(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

private struct FileDropTarget: NSViewRepresentable {
    let canAccept: Bool
    let onFiles: ([URL]) -> Void
    func makeNSView(context: Context) -> FinderDropView { FinderDropView() }
    func updateNSView(_ view: FinderDropView, context: Context) {
        view.canAccept = canAccept; view.onFiles = onFiles; view.needsDisplay = true
    }
}

@MainActor
private final class FinderDropView: NSView {
    var canAccept = false
    var onFiles: (([URL]) -> Void)?
    private var targeted = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drop files to Downloads. Choose Files is also available below.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        targeted = canAccept && !FinderFiles.read(sender).isEmpty; needsDisplay = true
        return targeted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { canAccept }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false; needsDisplay = true
        let urls = FinderFiles.read(sender)
        guard canAccept, !urls.isEmpty else { return false }
        onFiles?(urls); return true
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        (targeted ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill(); path.fill()
        (targeted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = targeted ? 2 : 1
        if !targeted { path.setLineDash([5, 4], count: 2, phase: 0) }
        path.stroke()
        let title = targeted ? "Release to send to Downloads" : canAccept ? "Drop files to Downloads" : "Reconnect to send files"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

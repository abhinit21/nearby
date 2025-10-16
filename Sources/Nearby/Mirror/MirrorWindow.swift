import AppKit
import AVFoundation
import Combine
import SwiftUI
import NearbyCore

/// The controller owns presentation only. AppModel owns the session lifetime.
@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate {
    var onUserClose: (() -> Void)?
    private weak var model: AppModel?
    private let session: ScrcpySession
    private let videoView: RemoteDisplayView
    private let controls: ControlShelfPanel
    private let controlsContent: ShelfContentView
    private var sharingPanel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var positioning = false
    private var draggingWindow = false
    private var dragEndTimer: Timer?
    private var resizeStart: (frame: NSRect, point: NSPoint)?
    private var programmaticClose = false
    private var isClosing = false
    private var screenIsOff: Bool

    init(model: AppModel, session: ScrcpySession, deviceName: String) {
        self.model = model
        self.session = session
        self.screenIsOff = model.turnOffDisplay
        videoView = RemoteDisplayView(session: session)
        controls = ControlShelfPanel(contentRect: NSRect(origin: .zero, size: MirrorLayout.controlSize),
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        controlsContent = ShelfContentView(frame: NSRect(origin: .zero, size: MirrorLayout.controlSize))
        let size = session.videoSize
        let height: CGFloat = 667
        let width = height * max(size.width, 1) / max(size.height, 1)
        let mirror = RemoteMirrorWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                        styleMask: [.borderless, .resizable, .miniaturizable],
                                        backing: .buffered, defer: false)
        super.init(window: mirror)
        mirror.title = deviceName
        mirror.isReleasedWhenClosed = false
        mirror.backgroundColor = .clear
        mirror.isOpaque = false
        mirror.hasShadow = true
        mirror.acceptsMouseMovedEvents = true
        mirror.contentView = videoView
        mirror.contentMinSize = NSSize(width: 160, height: 160 * max(size.height, 1) / max(size.width, 1))
        mirror.contentAspectRatio = NSSize(width: max(size.width, 1), height: max(size.height, 1))
        mirror.collectionBehavior = [.managed, .fullScreenPrimary]
        mirror.delegate = self
        mirror.reveal = { [weak self] in self?.revealControls() }
        mirror.fit = { [weak self] in self?.fitToScreen() }
        mirror.openSettings = { [weak model] in model?.showSettings() }
        mirror.quickPaste = { [weak model] in model?.pasteToPixel() }
        mirror.openSharing = { [weak self] in self?.showSharing() }
        mirror.setAccessibilityLabel("\(deviceName), remote Android display")
        let savedName = "NearbyMirror-\(model.activeDevice?.id ?? deviceName)"
        mirror.setFrameAutosaveName(savedName)
        if !mirror.setFrameUsingName(savedName) { mirror.center() }
        videoView.revealControls = { [weak self] in self?.revealControls() }
        videoView.dismissControls = { [weak self] in self?.dismissControls() }
        videoView.onPaste = { [weak model] in model?.pasteToPixel() }
        videoView.onFiles = { [weak model] urls in model?.sharing.acceptFiles(urls) }
        videoView.onPointerPresence = { [weak controlsContent] inside in controlsContent?.setMirrorHovered(inside) }

        controls.backgroundColor = .clear
        controls.isOpaque = false
        controls.hasShadow = true
        controls.isFloatingPanel = false
        controls.becomesKeyOnlyIfNeeded = true
        controls.hidesOnDeactivate = false
        controls.isReleasedWhenClosed = false
        controls.collectionBehavior = [.managed, .fullScreenAuxiliary]
        controls.contentView = controlsContent
        controls.title = "\(deviceName) controls"
        controls.setAccessibilityLabel("\(deviceName) navigation controls")
        controls.escape = { [weak self] in self?.dismissControls() }
        controlsContent.controller = self
        controlsContent.configure()
        controlsContent.setRemoteEnabled(session.isStreaming)

        let status = NSHostingView(rootView: MirrorStatusView(model: model, session: session))
        status.translatesAutoresizingMaskIntoConstraints = false
        videoView.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: videoView.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
            status.topAnchor.constraint(equalTo: videoView.topAnchor),
            status.bottomAnchor.constraint(equalTo: videoView.bottomAnchor)
        ])
        session.$isStreaming.sink { [weak status, weak controlsContent, weak session] streaming in
            MainActor.assumeIsolated {
                if let status {
                    if streaming && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0.12
                            status.animator().alphaValue = 0
                        } completionHandler: {
                            MainActor.assumeIsolated {
                                status.isHidden = session?.isStreaming == true
                                status.alphaValue = 1
                            }
                        }
                    } else {
                        status.isHidden = streaming
                        status.alphaValue = 1
                    }
                }
                controlsContent?.setRemoteEnabled(streaming)
            }
        }.store(in: &cancellables)
        session.$videoSize.removeDuplicates().sink { [weak self] size in
            MainActor.assumeIsolated { self?.updateVideoSize(size) }
        }.store(in: &cancellables)
        model.$turnOffDisplay.dropFirst().sink { [weak self] isOff in
            MainActor.assumeIsolated { self?.screenIsOff = isOff }
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isSessionForeground: Bool {
        window?.isKeyWindow == true || controls.isKeyWindow || sharingPanel?.isKeyWindow == true
    }

    func showSharing() {
        guard let model else { return }
        if sharingPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 424, height: 610),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "\(window?.title ?? "Pixel") · Clipboard & Files"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentMinSize = NSSize(width: 424, height: 480)
            panel.contentView = NSHostingView(rootView: ScrollView { SharingView(model: model, sharing: model.sharing) })
            panel.setFrameAutosaveName("Nearby.Sharing")
            if !panel.setFrameUsingName("Nearby.Sharing") {
                if let window { panel.setFrameOrigin(NSPoint(x: window.frame.maxX + 24, y: window.frame.maxY - 610)) }
                else { panel.center() }
            }
            sharingPanel = panel
        }
        if let panel = sharingPanel {
            // AppKit's titled-window constraint does not repair horizontal
            // overflow. Recheck the actual frame on every show, including
            // restored/reused panels after a display has been removed.
            let frame = SharingPanelLayout.reachableFrame(panel.frame, in: NSScreen.screens.map(\.visibleFrame),
                                                           fallback: (window?.screen ?? NSScreen.main)?.visibleFrame)
            if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
            panel.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        model.sharing.refreshContext()
    }

    func show() {
        guard let window else { return }
        positionControls()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        NSApp.activate(ignoringOtherApps: true)
        showControlsPanel()
    }

    /// The controls are persistent; this command now brings keyboard focus to them.
    func revealControls() {
        showControlsPanel()
        controls.makeKeyAndOrderFront(nil)
        controls.makeFirstResponder(controlsContent.firstControl)
    }

    func fitToScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        apply(MirrorLayout.fit(videoSize: session.videoSize, in: screen.visibleFrame))
    }

    func closeMirror() {
        guard !isClosing else { return }
        programmaticClose = true
        cleanUpPresentation()
        window?.close()
    }

    private func updateVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, let window else { return }
        let old = window.frame
        let newWidth = old.height * size.width / size.height
        window.contentAspectRatio = size
        window.contentMinSize = NSSize(width: 160, height: 160 * size.height / size.width)
        let proposed = NSRect(x: old.midX - newWidth / 2, y: old.minY,
                              width: newWidth, height: old.height)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? proposed
        apply(MirrorLayout.constrain(videoFrame: proposed, in: visible))
        videoView.needsLayout = true
    }

    private func showControlsPanel() {
        guard let window, window.isVisible, !window.isMiniaturized, !isClosing else { return }
        positionControls()
        if controls.parent == nil { window.addChildWindow(controls, ordered: .above) }
        controls.orderFront(nil)
    }

    private func positionControls() {
        guard !positioning, !isClosing, let window else { return }
        if draggingWindow || resizeStart != nil {
            // Let the mirror cross a display boundary before constraining the
            // linked windows to the destination screen at the end of the drag.
            let size = MirrorLayout.controlSize
            let controlFrame = NSRect(x: window.frame.midX - size.width / 2,
                                      y: window.frame.minY - MirrorLayout.gap - size.height,
                                      width: size.width, height: size.height)
            let frames = MirrorFrames(video: window.frame, controls: controlFrame)
            controls.setFrame(frames.controls, display: controls.isVisible)
            return
        }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        apply(MirrorLayout.constrain(videoFrame: window.frame, in: visible))
    }

    private func apply(_ frames: MirrorFrames) {
        guard !positioning, let window else { return }
        positioning = true
        defer { positioning = false }
        if window.frame != frames.video { window.setFrame(frames.video, display: true) }
        controls.setFrame(frames.controls, display: controls.isVisible)
    }

    func dismissControls() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(videoView)
        showControlsPanel()
    }

    func dragWindow(with event: NSEvent) {
        guard !draggingWindow else { return }
        draggingWindow = true
        controlsContent.setManipulating(true)
        NSCursor.closedHand.set()
        // Native window dragging can consume mouse-up and return immediately.
        // Observe button release without blocking frame decoding or the UI.
        dragEndTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.dragEndTimer?.invalidate(); self.dragEndTimer = nil; self.draggingWindow = false
                    self.positionControls()
                    self.controlsContent.setManipulating(false)
                    self.controlsContent.restoreMoveCursor()
                }
            }
        }
        dragEndTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        window?.performDrag(with: event)
    }

    func beginResize(at point: NSPoint) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        resizeStart = (window.frame, point)
        controlsContent.setManipulating(true)
    }

    var isMovingMirror: Bool { draggingWindow }

    func resize(to point: NSPoint) {
        guard let start = resizeStart, start.frame.height > 0, let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? start.frame
        apply(MirrorResizeGesture.frames(startFrame: start.frame, mouseDown: start.point,
                                        mouseDragged: point, in: visible, minimumSize: window.contentMinSize))
    }

    func endResize() {
        resizeStart = nil
        positionControls()
        controlsContent.setManipulating(false)
    }

    func androidKey(_ code: UInt32) {
        guard session.isStreaming else { return }
        session.keycode(code)
    }

    func userClose() { window?.performClose(nil) }
    func minimize() { window?.miniaturize(nil); controls.orderOut(nil) }

    func openSessionMenu(from button: NSButton) {
        let menu = NSMenu(title: "Session")
        menu.delegate = self
        func item(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
            result.target = self
            if let symbol { result.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(result)
            return result
        }
        let clipboard = item("Share Text Clipboard", #selector(toggleClipboard))
        clipboard.state = model?.shareClipboard == true ? .on : .off
        let power = item("Turn Off Phone Display", #selector(toggleDisplay))
        power.state = screenIsOff ? .on : .off
        power.isEnabled = session.isStreaming
        menu.addItem(.separator())
        let capture = item("Take Screenshot…", #selector(screenshot), symbol: "camera")
        capture.isEnabled = session.isStreaming
        capture.keyEquivalent = "s"
        capture.keyEquivalentModifierMask = [.command, .shift]
        let fit = item("Fit to Screen", #selector(fit), symbol: "arrow.up.left.and.arrow.down.right")
        fit.keyEquivalent = "0"
        fit.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())
        _ = item("Disconnect", #selector(disconnect), symbol: "power")
        menu.autoenablesItems = false
        button.highlight(true)
        defer { button.highlight(false) }
        menu.update()
        if let panel = button.window {
            let buttonFrame = panel.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
            let size = menu.size
            // NSMenu anchors its top edge at the supplied point. Place the
            // compact menu above the dock so a bottom-edge anchor cannot turn
            // an otherwise short menu into a scrolling menu.
            let x = min(max(buttonFrame.maxX + 12, visible.minX + 8), visible.maxX - size.width - 8)
            let y = min(max(buttonFrame.maxY + size.height + 8, visible.minY + size.height + 8), visible.maxY - 8)
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: nil)
        }
    }

    @objc private func toggleClipboard() { model?.shareClipboard.toggle() }
    @objc func quickPaste() { model?.pasteToPixel() }
    @objc func openSharing() { showSharing() }
    @objc private func toggleDisplay() {
        screenIsOff.toggle()
        session.setScreenPower(!screenIsOff)
    }
    @objc private func screenshot() { model?.takeScreenshot() }
    @objc private func fit() { fitToScreen() }
    @objc private func disconnect() { model?.disconnect() }

    func windowDidMove(_ notification: Notification) { positionControls() }
    func windowDidResize(_ notification: Notification) { positionControls() }
    func windowDidChangeScreen(_ notification: Notification) { positionControls() }
    func windowDidBecomeKey(_ notification: Notification) { showControlsPanel() }
    func windowDidMiniaturize(_ notification: Notification) { controls.orderOut(nil) }
    func windowDidDeminiaturize(_ notification: Notification) { showControlsPanel() }
    func windowWillClose(_ notification: Notification) {
        isClosing = true
        if let window, !window.frameAutosaveName.isEmpty {
            window.saveFrame(usingName: window.frameAutosaveName)
        }
        cleanUpPresentation()
        if !programmaticClose { onUserClose?() }
    }

    private func cleanUpPresentation() {
        dragEndTimer?.invalidate(); dragEndTimer = nil
        resizeStart = nil; draggingWindow = false
        controlsContent.setManipulating(false)
        window?.removeChildWindow(controls)
        controls.orderOut(nil)
        sharingPanel?.close(); sharingPanel = nil
        cancellables.removeAll()
    }
}

@MainActor
private final class RemoteMirrorWindow: NSWindow {
    var reveal: (() -> Void)?
    var fit: (() -> Void)?
    var openSettings: (() -> Void)?
    var quickPaste: (() -> Void)?
    var openSharing: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) { close() }
    override func performMiniaturize(_ sender: Any?) { miniaturize(sender) }
    override func performZoom(_ sender: Any?) { fit?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == [.command, .shift], key == "v" { quickPaste?(); return true }
        if modifiers == [.command, .shift], key == "f" { openSharing?(); return true }
        if modifiers == .command {
            switch key {
            case "w": performClose(nil); return true
            case "m": miniaturize(nil); return true
            case "q": NSApp.terminate(nil); return true
            case ",": openSettings?(); return true
            default: break
            }
        }
        if (modifiers == [.option, .command] && key == "t") ||
            (modifiers == .control && event.keyCode == 96) {
            reveal?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

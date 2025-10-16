import AppKit
import NearbyCore

@MainActor
final class ControlShelfPanel: NSPanel {
    var escape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { parent?.performClose(sender) }
    override func performMiniaturize(_ sender: Any?) { parent?.performMiniaturize(sender) }
    override func performZoom(_ sender: Any?) { parent?.performZoom(sender) }
    override func becomeKey() {
        super.becomeKey()
        (contentView as? ShelfContentView)?.refreshHandleVisibility()
    }
    override func resignKey() {
        super.resignKey()
        (contentView as? ShelfContentView)?.refreshHandleVisibility()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), parent?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { escape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape?() } else { super.keyDown(with: event) }
    }
}

/// The icon dock stays visible. Its two side handles reveal without moving buttons.
@MainActor
final class ShelfContentView: NSView {
    weak var controller: MirrorWindowController?
    private(set) var moveGrip: MirrorMoveGripView?
    private(set) var resizeGrip: MirrorResizeGripView?
    private var glass: NSGlassEffectView?
    private var pointerTracking: NSTrackingArea?
    private var pointerInside = false
    private var mirrorHovered = false
    private var hoverExitTask: Task<Void, Never>?
    private var isManipulating = false
    private var backControl: NSButton?
    private var menuControl: NSButton?
    private(set) var buttons: [NSButton] = []
    private var remoteButtons: [NSButton] = []
    var firstControl: NSButton? { backControl?.isEnabled == true ? backControl : menuControl }

    func setRemoteEnabled(_ enabled: Bool) {
        remoteButtons.forEach { $0.isEnabled = enabled }
        if !enabled, window?.isKeyWindow == true { window?.makeFirstResponder(firstControl) }
    }

    func refreshHandleVisibility() {
        let visible = pointerInside || mirrorHovered || window?.isKeyWindow == true || isManipulating
        moveGrip?.isRevealed = visible
        resizeGrip?.isRevealed = visible
    }

    func setManipulating(_ active: Bool) {
        isManipulating = active
        refreshHandleVisibility()
    }

    func setMirrorHovered(_ inside: Bool) {
        hoverExitTask?.cancel()
        if inside {
            mirrorHovered = true
            refreshHandleVisibility()
        } else {
            // Bridge the gap between video and dock without flashing the handles.
            hoverExitTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(280)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                mirrorHovered = false
                refreshHandleVisibility()
                hoverExitTask = nil
            }
        }
    }

    override func updateTrackingAreas() {
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: bounds,
                                 options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                 owner: self)
        pointerTracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
        if let window, window.isVisible {
            pointerInside = bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        }
        refreshHandleVisibility()
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; refreshHandleVisibility() }
    override func mouseExited(with event: NSEvent) { pointerInside = false; refreshHandleVisibility() }

    func restoreMoveCursor() {
        guard NSApp.isActive, let moveGrip, let window else { return }
        let point = moveGrip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if moveGrip.bounds.contains(point) { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
    }

    override func layout() {
        super.layout()
        glass?.frame = MirrorLayout.dockFrame(in: bounds)
        moveGrip?.frame = MirrorLayout.moveHandleFrame(in: bounds)
        resizeGrip?.frame = MirrorLayout.resizeHandleFrame(in: bounds)
    }

    func configure() {
        guard glass == nil else { return }
        let effect = NSGlassEffectView(frame: MirrorLayout.dockFrame(in: bounds))
        effect.cornerRadius = 28
        effect.style = .regular
        if #available(macOS 27, *) { effect.effectIsInteractive = true }
        let content = NSView(frame: effect.bounds)
        effect.contentView = content
        addSubview(effect)
        glass = effect

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        let back = control("chevron.backward", label: "Back", help: "Back (⌃⌘B)", action: #selector(back))
        let home = control("house", label: "Home", help: "Home (⌃⌘H)", action: #selector(home))
        let overview = control("rectangle.stack", label: "Recent Apps", help: "Recent Apps (⌃⌘O)", action: #selector(overview))
        let paste = control("doc.on.clipboard", label: "Paste to Pixel", help: "Paste Mac text to Pixel (⇧⌘V). Select a text field on Pixel first.", action: #selector(pasteText))
        let files = control("folder", label: "Clipboard and Files", help: "Clipboard status and file transfers (⇧⌘F)", action: #selector(files))
        let menu = control("ellipsis", label: "More", help: "Session and window actions", action: #selector(more(_:)))
        backControl = back
        menuControl = menu
        remoteButtons = [back, home, overview, paste]
        buttons = [back, home, overview, paste, files, menu]
        for (index, button) in buttons.enumerated() {
            if index == 3 || index == 5 { stack.addArrangedSubview(separator()) }
            // A plain slot keeps NSButton's optical alignment insets from
            // changing the actual 44-point pointer target or icon spacing.
            let slot = NSView(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.widthAnchor.constraint(equalToConstant: 44).isActive = true
            slot.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.frame = slot.bounds
            button.autoresizingMask = [.width, .height]
            slot.addSubview(button)
            stack.addArrangedSubview(slot)
            button.nextKeyView = buttons[(index + 1) % buttons.count]
            (button as? MirrorControlButton)?.onTab = { [weak self, weak button] backwards in
                guard let self, let button else { return }
                focusControl(after: button, backwards: backwards)
            }
        }

        let move = MirrorMoveGripView(frame: MirrorLayout.moveHandleFrame(in: bounds))
        move.controller = controller
        addSubview(move)
        moveGrip = move
        let resize = MirrorResizeGripView(frame: MirrorLayout.resizeHandleFrame(in: bounds))
        resize.controller = controller
        addSubview(resize)
        resizeGrip = resize
        refreshHandleVisibility()
        window?.recalculateKeyViewLoop()
    }

    private func separator() -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        slot.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(line)
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalTo: slot.heightAnchor),
            line.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: slot.centerYAnchor)
        ])
        return slot
    }

    private func focusControl(after current: NSButton, backwards: Bool) {
        guard let start = buttons.firstIndex(of: current), !buttons.isEmpty else { return }
        for offset in 1...buttons.count {
            let index = (start + (backwards ? -offset : offset) + buttons.count) % buttons.count
            if buttons[index].isEnabled {
                window?.makeFirstResponder(buttons[index])
                return
            }
        }
    }

    private func control(_ symbol: String, label: String, help: String, action: Selector) -> NSButton {
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(configuration) ?? NSImage()
        let button = MirrorControlButton(image: icon, target: self, action: action)
        button.title = ""
        button.identifier = NSUserInterfaceItemIdentifier(symbol)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = help
        button.setAccessibilityLabel(label)
        button.refusesFirstResponder = false
        return button
    }

    @objc private func back() { controller?.androidKey(4) }
    @objc private func home() { controller?.androidKey(3) }
    @objc private func overview() { controller?.androidKey(187) }
    @objc private func more(_ sender: NSButton) { controller?.openSessionMenu(from: sender) }
    @objc private func pasteText() { controller?.quickPaste() }
    @objc private func files() { controller?.showSharing() }
}

/// Explicit dock navigation works even when macOS limits Tab to text controls.
@MainActor
final class MirrorControlButton: NSButton {
    var onTab: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            onTab?(modifiers == .shift)
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
class MirrorPointerGripView: NSView {
    weak var controller: MirrorWindowController?
    private var cursorTracking: NSTrackingArea?
    var interactionCursor: NSCursor { .arrow }
    var isRevealed = false {
        didSet {
            subviews.forEach { $0.isHidden = !isRevealed }
            needsDisplay = true
        }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func updateTrackingAreas() {
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: bounds,
                                 options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                 owner: self)
        cursorTracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func cursorUpdate(with event: NSEvent) { interactionCursor.set() }
    override func mouseEntered(with event: NSEvent) { interactionCursor.set() }
    override func mouseExited(with event: NSEvent) {
        if controller?.isMovingMirror != true { NSCursor.arrow.set() }
    }
    func installIcon(_ symbol: String, size: CGFloat) {
        let image = NSImageView(frame: NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size))
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium))
        image.contentTintColor = .labelColor
        image.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        image.setAccessibilityElement(false)
        addSubview(image)
    }
}

@MainActor
final class MirrorMoveGripView: MirrorPointerGripView {
    override var interactionCursor: NSCursor { controller?.isMovingMirror == true ? .closedHand : .openHand }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let glass = NSGlassEffectView(frame: bounds)
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = 10
        glass.style = .regular
        addSubview(glass)
        let dots = MoveGripDotsView(frame: bounds)
        dots.autoresizingMask = [.width, .height]
        dots.setAccessibilityElement(false)
        addSubview(dots)
        toolTip = "Drag to move the mirror"
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Move Mirror")
        setAccessibilityHelp("Drag this handle to move the phone and floating controls together.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func mouseDown(with event: NSEvent) { controller?.dragWindow(with: event) }
}

@MainActor
private final class MoveGripDotsView: NSView {
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.setFill()
        for row in 0..<3 {
            for column in 0..<2 {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX - 3.75 + CGFloat(column) * 5,
                                          y: bounds.midY - 6.25 + CGFloat(row) * 5,
                                          width: 2.5, height: 2.5)).fill()
            }
        }
    }
}

@MainActor
final class MirrorResizeGripView: MirrorPointerGripView {
    override var interactionCursor: NSCursor { .frameResize(position: .bottomRight, directions: .all) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let glass = NSGlassEffectView(frame: bounds)
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = 10
        glass.style = .regular
        addSubview(glass)
        installIcon("arrow.up.left.and.arrow.down.right", size: 14)
        toolTip = "Drag to resize the mirror"
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Resize Mirror")
        setAccessibilityHelp("Drag to resize the phone while keeping its proportions.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
    override func mouseDown(with event: NSEvent) {
        interactionCursor.set()
        controller?.beginResize(at: screenPoint(event))
    }
    override func mouseDragged(with event: NSEvent) {
        interactionCursor.set()
        controller?.resize(to: screenPoint(event))
    }
    override func mouseUp(with event: NSEvent) {
        controller?.resize(to: screenPoint(event))
        controller?.endResize()
        let local = convert(window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero, from: nil)
        if NSApp.isActive, bounds.contains(local) { interactionCursor.set() }
        else { NSCursor.arrow.set() }
    }
}

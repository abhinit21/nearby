import AppKit
import AVFoundation
import NearbyCore

/// The app-owned shape clips presentation and pointer hits; video coordinates stay rectangular.
@MainActor
final class RemoteDisplayView: NSView, @MainActor NSTextInputClient, @MainActor NSMenuItemValidation {
    let session: ScrcpySession
    var revealControls: (() -> Void)?
    var dismissControls: (() -> Void)?
    var onPaste: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onPointerPresence: ((Bool) -> Void)?
    private var pointerTracking: NSTrackingArea?
    private var dropOverlay: MirrorDropOverlay?
    private let shapeMask = CAShapeLayer()
    private var touchIsDown = false
    private var lastPoint = CGPoint(x: 0.5, y: 0.5)
    private var marked = NSAttributedString(string: "")

    init(session: ScrcpySession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.mask = shapeMask
        session.displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(session.displayLayer)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Android remote display")
        setAccessibilityHelp("Remote screen pixels. Navigation controls remain below the display. Control-F5 focuses them.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: bounds,
                                 options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                 owner: self)
        pointerTracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
        if let window, window.isVisible {
            let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            onPointerPresence?(bounds.contains(local))
        }
    }
    override func mouseEntered(with event: NSEvent) { onPointerPresence?(true) }
    override func mouseExited(with event: NSEvent) { onPointerPresence?(false) }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.displayLayer.frame = bounds
        let path = MirrorShape.path(in: bounds)
        shapeMask.frame = bounds
        shapeMask.path = path
        layer?.shadowPath = path
        CATransaction.commit()
        window?.invalidateShadow()
    }

    private func normalized(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let imageRect = AVMakeRect(aspectRatio: session.videoSize, insideRect: bounds)
        guard imageRect.width > 0, imageRect.height > 0,
              clamp || (imageRect.contains(p) && MirrorShape.path(in: bounds).contains(p)) else { return nil }
        return CGPoint(x: min(max((p.x - imageRect.minX) / imageRect.width, 0), 1),
                       y: min(max(1 - (p.y - imageRect.minY) / imageRect.height, 0), 1))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard session.isStreaming, let p = normalized(event) else { return }
        touchIsDown = true
        lastPoint = p
        session.touch(x: p.x, y: p.y, phase: .down)
    }
    override func mouseDragged(with event: NSEvent) {
        guard session.isStreaming, touchIsDown, let p = normalized(event, clamp: true) else { return }
        lastPoint = p
        session.touch(x: p.x, y: p.y, phase: .move)
    }
    override func mouseUp(with event: NSEvent) {
        guard touchIsDown else { return }
        touchIsDown = false
        let p = normalized(event, clamp: true) ?? lastPoint
        if session.isStreaming { session.touch(x: p.x, y: p.y, phase: .up) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if session.isStreaming, normalized(event) != nil { session.keycode(4) }
    }
    override func scrollWheel(with event: NSEvent) {
        guard session.isStreaming, let p = normalized(event) else { return }
        let divisor: Double = event.hasPreciseScrollingDeltas ? 35 : 1
        session.scroll(x: p.x, y: p.y,
                       dx: min(max(Double(event.scrollingDeltaX) / divisor, -16), 16),
                       dy: min(max(Double(event.scrollingDeltaY) / divisor, -16), 16))
    }
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.contains(.command) { super.keyDown(with: event); return }
        if flags == .control && event.keyCode == 96 { revealControls?(); return }
        guard session.isStreaming else { return }
        if !hasMarkedText() {
            let android: [UInt16: UInt32] = [36: 66, 76: 66, 48: 61, 51: 67, 117: 112, 53: 111,
                                            123: 21, 124: 22, 125: 20, 126: 19, 115: 122, 119: 123,
                                            116: 92, 121: 93]
            if let code = android[event.keyCode] { session.keycode(code); return }
        }
        interpretKeyEvents([event])
    }

    @objc func paste(_ sender: Any?) {
        onPaste?()
    }
    @objc func copy(_ sender: Any?) {
        if session.isStreaming { session.keycode(278) }
    }
    @objc func cut(_ sender: Any?) {
        if session.isStreaming { session.keycode(277) }
    }
    override func selectAll(_ sender: Any?) {
        if session.isStreaming { session.keycode(29, metaState: 0x1000) }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)) {
            return session.isStreaming && NSPasteboard.general.string(forType: .string)?.isEmpty == false
        }
        return session.isStreaming
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        marked = NSAttributedString(string: "")
        if session.isStreaming && !text.isEmpty { session.text(text) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
    }
    func unmarkText() { marked = NSAttributedString(string: "") }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(NSRect(x: bounds.midX, y: bounds.minY + 20, width: 1, height: 18)) ?? .zero
    }
    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) { dismissControls?() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !FinderFiles.read(sender).isEmpty else { return [] }
        if dropOverlay == nil {
            let overlay = MirrorDropOverlay(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay); dropOverlay = overlay
        }
        dropOverlay?.canAccept = session.isStreaming
        dropOverlay?.isHidden = false; dropOverlay?.needsDisplay = true
        return session.isStreaming ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropOverlay?.isHidden = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { session.isStreaming }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOverlay?.isHidden = true
        let urls = FinderFiles.read(sender)
        guard session.isStreaming, !urls.isEmpty else { return false }
        onFiles?(urls); return true
    }
}

@MainActor
private final class MirrorDropOverlay: NSView {
    var canAccept = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill(); bounds.fill()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 10), xRadius: 26, yRadius: 26)
        NSColor.controlAccentColor.setStroke(); outline.lineWidth = 3; outline.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let text = canAccept ? "Drop files to Downloads\nExisting files are kept." : "Reconnect to Pixel\nbefore sending files."
        text.draw(in: NSRect(x: 24, y: bounds.midY - 40, width: bounds.width - 48, height: 80), withAttributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
    }
}

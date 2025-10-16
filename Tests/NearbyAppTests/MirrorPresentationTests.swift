import AppKit
import SwiftUI
import XCTest
import NearbyCore
@testable import Nearby

@MainActor
final class MirrorPresentationTests: XCTestCase {
    func testContinuousShapeKeepsStraightEdgesAndScalesAcrossRotation() {
        let portrait = CGRect(x: 0, y: 0, width: 300, height: 670)
        let landscape = CGRect(x: 0, y: 0, width: 670, height: 300)
        XCTAssertEqual(MirrorShape.cornerRadius(in: portrait), 30)
        XCTAssertEqual(MirrorShape.cornerRadius(in: landscape), 30)
        for bounds in [portrait, landscape, CGRect(x: -200, y: -80, width: 160, height: 360)] {
            let path = MirrorShape.path(in: bounds)
            XCTAssertEqual(path.boundingBoxOfPath, bounds)
            XCTAssertTrue(path.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
            XCTAssertTrue(path.contains(CGPoint(x: bounds.minX + 0.1, y: bounds.midY)))
            XCTAssertTrue(path.contains(CGPoint(x: bounds.midX, y: bounds.maxY - 0.1)))
            XCTAssertFalse(path.contains(CGPoint(x: bounds.minX + 0.1, y: bounds.minY + 0.1)))
            XCTAssertFalse(path.contains(CGPoint(x: bounds.maxX - 0.1, y: bounds.maxY - 0.1)))
        }
        let small = MirrorShape.path(in: CGRect(x: 0, y: 0, width: 150, height: 335))
        let large = MirrorShape.path(in: portrait)
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 15, y: 15), CGPoint(x: 0.1, y: 100), CGPoint(x: 75, y: 330)] {
            XCTAssertEqual(small.contains(point), large.contains(CGPoint(x: point.x * 2, y: point.y * 2)))
        }
    }

    func testShapeRejectsInvalidBounds() {
        for bounds in [CGRect.zero, CGRect.null, CGRect.infinite,
                       CGRect(x: 0, y: 0, width: -1, height: 40),
                       CGRect(x: CGFloat.nan, y: 0, width: 200, height: 400)] {
            XCTAssertTrue(MirrorShape.path(in: bounds).isEmpty)
        }
    }

    func testDisplayUsesSharedContinuousMaskAtEverySize() throws {
        let session = ScrcpySession(adb: ADBClient(executableURL: URL(fileURLWithPath: "/usr/bin/false")),
                                    serverURL: URL(fileURLWithPath: "/not-started"), serverVersion: ScrcpySession.protocolVersion)
        let display = RemoteDisplayView(session: session)
        for size in [CGSize(width: 355, height: 796), CGSize(width: 796, height: 355), CGSize(width: 160, height: 359)] {
            display.setFrameSize(size)
            display.layout()
            let mask = try XCTUnwrap(display.layer?.mask as? CAShapeLayer)
            XCTAssertEqual(mask.path, MirrorShape.path(in: display.bounds))
            XCTAssertEqual(session.displayLayer.frame, display.bounds)
        }
    }

    func testDockHasSixAccessibleIconTargetsAndSessionFallback() throws {
        let shelf = ShelfContentView(frame: CGRect(origin: .zero, size: MirrorLayout.controlSize))
        shelf.configure()
        shelf.layoutSubtreeIfNeeded()
        let expected = ["chevron.backward", "house", "rectangle.stack", "doc.on.clipboard", "folder", "ellipsis"]
        XCTAssertEqual(shelf.buttons.map { $0.identifier?.rawValue }, expected)
        XCTAssertEqual(shelf.buttons.map { $0.accessibilityLabel() }, ["Back", "Home", "Recent Apps", "Paste to Pixel", "Clipboard and Files", "More"])
        let targets = shelf.buttons.map { $0.convert($0.bounds, to: shelf) }
        let dock = MirrorLayout.dockFrame(in: shelf.bounds)
        for (index, button) in shelf.buttons.enumerated() {
            XCTAssertNotNil(NSImage(systemSymbolName: expected[index], accessibilityDescription: nil))
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertEqual(button.title, "")
            XCTAssertFalse(button.toolTip?.isEmpty ?? true)
            XCTAssertEqual(button.frame.size, CGSize(width: 44, height: 44))
            XCTAssertTrue(button.nextKeyView === shelf.buttons[(index + 1) % shelf.buttons.count])
            XCTAssertTrue(dock.contains(targets[index]))
            XCTAssertEqual(targets[index].midY, dock.midY, accuracy: 0.001)
            if index > 0 { XCTAssertLessThanOrEqual(targets[index - 1].maxX, targets[index].minX) }
        }
        XCTAssertFalse(try XCTUnwrap(shelf.moveGrip).frame.intersects(dock))
        XCTAssertFalse(try XCTUnwrap(shelf.resizeGrip).frame.intersects(dock))
        shelf.setRemoteEnabled(false)
        XCTAssertEqual(shelf.buttons.map(\.isEnabled), [false, false, false, false, true, true])
        XCTAssertTrue(shelf.firstControl === shelf.buttons.last)
        shelf.setRemoteEnabled(true)
        XCTAssertTrue(shelf.firstControl === shelf.buttons.first)
    }

    func testHoverRevealsOnlyDecorationsWithoutMovingTargets() throws {
        let shelf = ShelfContentView(frame: CGRect(origin: .zero, size: MirrorLayout.controlSize))
        shelf.configure()
        shelf.layoutSubtreeIfNeeded()
        let move = try XCTUnwrap(shelf.moveGrip), resize = try XCTUnwrap(shelf.resizeGrip)
        let originalFrames = shelf.buttons.map { $0.convert($0.bounds, to: shelf) }
        XCTAssertFalse(move.isRevealed)
        XCTAssertFalse(resize.isRevealed)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        shelf.mouseEntered(with: event)
        XCTAssertTrue(move.isRevealed)
        XCTAssertTrue(resize.isRevealed)
        shelf.setManipulating(true)
        shelf.mouseExited(with: event)
        XCTAssertTrue(move.isRevealed, "A drag remains discoverable after leaving the shelf")
        XCTAssertTrue(resize.isRevealed)
        shelf.setManipulating(false)
        XCTAssertFalse(move.isRevealed)
        XCTAssertFalse(resize.isRevealed)
        XCTAssertFalse(move.isHidden)
        XCTAssertFalse(resize.isHidden)
        XCTAssertEqual(shelf.buttons.map { $0.convert($0.bounds, to: shelf) }, originalFrames)
    }

    func testKeyboardFocusedShelfRevealsHandlesUntilFocusLeaves() throws {
        let panel = FocusTestPanel(contentRect: CGRect(origin: .zero, size: MirrorLayout.controlSize),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        defer { panel.close() }
        let shelf = ShelfContentView(frame: CGRect(origin: .zero, size: MirrorLayout.controlSize))
        panel.contentView = shelf
        shelf.configure()
        panel.hasTestFocus = true
        shelf.refreshHandleVisibility()
        XCTAssertTrue(try XCTUnwrap(shelf.moveGrip).isRevealed)
        XCTAssertTrue(try XCTUnwrap(shelf.resizeGrip).isRevealed)
        panel.hasTestFocus = false
        shelf.refreshHandleVisibility()
        XCTAssertFalse(try XCTUnwrap(shelf.moveGrip).isRevealed)
        XCTAssertFalse(try XCTUnwrap(shelf.resizeGrip).isRevealed)
    }

    func testTabNavigationWrapsAndSkipsUnavailableRemoteActions() throws {
        let panel = FocusTestPanel(contentRect: CGRect(origin: .zero, size: MirrorLayout.controlSize),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        defer { panel.close() }
        let shelf = ShelfContentView(frame: CGRect(origin: .zero, size: MirrorLayout.controlSize))
        panel.contentView = shelf
        shelf.configure()
        XCTAssertTrue(panel.makeFirstResponder(shelf.buttons[0]))
        func tab(backwards: Bool = false) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: backwards ? .shift : [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            try XCTUnwrap(panel.firstResponder as? NSButton).keyDown(with: event)
        }
        for index in [1, 2, 3, 4, 5, 0] {
            try tab()
            XCTAssertTrue(panel.firstResponder === shelf.buttons[index])
        }
        try tab(backwards: true)
        XCTAssertTrue(panel.firstResponder === shelf.buttons[5])
        shelf.setRemoteEnabled(false)
        try tab()
        XCTAssertTrue(panel.firstResponder === shelf.buttons[4])
        try tab()
        XCTAssertTrue(panel.firstResponder === shelf.buttons[5])
    }

    func testPhoneHoverRevealsHandlesAndBridgesGapWithoutStaleHiding() async throws {
        let shelf = ShelfContentView(frame: CGRect(origin: .zero, size: MirrorLayout.controlSize))
        shelf.configure()
        let move = try XCTUnwrap(shelf.moveGrip), resize = try XCTUnwrap(shelf.resizeGrip)
        XCTAssertTrue(move.subviews.allSatisfy(\.isHidden))
        shelf.setMirrorHovered(true)
        XCTAssertTrue(move.isRevealed)
        XCTAssertTrue(resize.isRevealed)
        XCTAssertTrue(move.subviews.allSatisfy { !$0.isHidden })
        shelf.setMirrorHovered(false)
        XCTAssertTrue(move.isRevealed, "Keep the handle visible while crossing the gap")
        shelf.setMirrorHovered(true)
        try await Task.sleep(for: .milliseconds(360))
        XCTAssertTrue(move.isRevealed, "Re-entry cancels a pending hide")
        shelf.setMirrorHovered(false)
        try await Task.sleep(for: .milliseconds(360))
        XCTAssertFalse(move.isRevealed)
        XCTAssertFalse(resize.isRevealed)
        XCTAssertTrue(move.subviews.allSatisfy(\.isHidden))
    }
}

/// This unshown window models focus without activating or changing user windows.
@MainActor
private final class FocusTestPanel: NSPanel {
    var hasTestFocus = false
    override var isKeyWindow: Bool { hasTestFocus }
}

import CoreGraphics
import Testing
@testable import NearbyCore

@Suite struct MirrorResizeGestureTests {
    private let tolerance: CGFloat = 0.000_001

    @Test func expandAndShrinkPreserveAspectAndTopLeftWhenTheyFit() {
        let start = CGRect(x: 450, y: 200, width: 300, height: 600)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 1000)
        let down = CGPoint(x: 790, y: 180)
        let expanded = MirrorResizeGesture.frames(startFrame: start, mouseDown: down,
            mouseDragged: CGPoint(x: down.x + 25, y: down.y - 50), in: screen,
            minimumSize: CGSize(width: 160, height: 320))
        let shrunk = MirrorResizeGesture.frames(startFrame: start, mouseDown: down,
            mouseDragged: CGPoint(x: down.x - 25, y: down.y + 50), in: screen,
            minimumSize: CGSize(width: 160, height: 320))
        #expect(abs(expanded.video.height - 650) < tolerance)
        #expect(abs(shrunk.video.height - 550) < tolerance)
        for result in [expanded, shrunk] {
            #expect(abs(result.video.width / result.video.height - 0.5) < tolerance)
            #expect(abs(result.video.minX - start.minX) < tolerance)
            #expect(abs(result.video.maxY - start.maxY) < tolerance)
            #expect(screen.insetBy(dx: 8, dy: 8).contains(result.total))
        }
    }

    @Test func hugeDragClampsTheWholeAssemblyIncludingDockAndHandle() {
        let start = CGRect(x: 450, y: 200, width: 300, height: 600)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let result = MirrorResizeGesture.frames(startFrame: start,
            mouseDown: CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude),
            mouseDragged: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude),
            in: screen, minimumSize: CGSize(width: 160, height: 320))
        #expect(screen.insetBy(dx: 8, dy: 8).contains(result.total))
        #expect(abs(result.video.width / result.video.height - 0.5) < tolerance)
        #expect(abs(result.video.maxY - start.maxY) < tolerance)
        #expect(abs(result.controls.minY - 8) < tolerance)
        #expect(result.controls.contains(result.resizeHandle))
        #expect(result.controls.contains(result.moveHandle))
        #expect(result.resizeHandle.size == MirrorLayout.resizeHandleSize)
    }

    @Test func landscapeExpansionCanReachTheRightEdgeWithoutAnExternalHandleMargin() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 1000)
        let start = CGRect(x: 400, y: 450, width: 600, height: 300)
        let down = CGPoint(x: 890, y: 400)
        let result = MirrorResizeGesture.frames(startFrame: start, mouseDown: down,
            mouseDragged: CGPoint(x: down.x + 1000, y: down.y - 500), in: screen,
            minimumSize: CGSize(width: 160, height: 80))
        #expect(abs(result.video.minX - start.minX) < tolerance)
        #expect(abs(result.video.maxY - start.maxY) < tolerance)
        #expect(abs(result.video.maxX - 1432) < tolerance)
        #expect(abs(result.video.width / result.video.height - 2) < tolerance)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(result.total))
    }

    @Test func minimumAndZeroMovementAreStableAndInvalidPointerDoesNotJump() {
        let start = CGRect(x: 400, y: 150, width: 300, height: 600)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let minimum = CGSize(width: 200, height: 400)
        let down = CGPoint(x: 740, y: 130)
        let unchanged = MirrorResizeGesture.frames(startFrame: start, mouseDown: down,
            mouseDragged: down, in: screen, minimumSize: minimum)
        #expect(unchanged.video == start)
        let shrunk = MirrorResizeGesture.frames(startFrame: start, mouseDown: down,
            mouseDragged: CGPoint(x: down.x - 10_000, y: down.y + 10_000), in: screen, minimumSize: minimum)
        #expect(abs(shrunk.video.width - 200) < tolerance)
        #expect(abs(shrunk.video.height - 400) < tolerance)
        #expect(abs(shrunk.video.maxY - start.maxY) < tolerance)
        let invalid = MirrorResizeGesture.frames(startFrame: start, mouseDown: down,
            mouseDragged: CGPoint(x: CGFloat.nan, y: 0), in: screen, minimumSize: minimum)
        #expect(invalid == unchanged)
    }

    @Test func negativeScreenOriginsUseGlobalCoordinatesWithoutLosingAnchor() {
        let screen = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let start = CGRect(x: -1600, y: -800, width: 300, height: 600)
        let down = CGPoint(x: -1260, y: -820)
        let result = MirrorResizeGesture.frames(startFrame: start, mouseDown: down,
            mouseDragged: CGPoint(x: down.x + 50, y: down.y - 100), in: screen,
            minimumSize: CGSize(width: 160, height: 320))
        #expect(abs(result.video.height - 700) < tolerance)
        #expect(abs(result.video.width - 350) < tolerance)
        #expect(abs(result.video.minX - start.minX) < tolerance)
        #expect(abs(result.video.maxY - start.maxY) < tolerance)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(result.total))
    }
}

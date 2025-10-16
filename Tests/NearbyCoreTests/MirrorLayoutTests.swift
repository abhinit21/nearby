import CoreGraphics
import Testing
@testable import NearbyCore

@Suite struct MirrorLayoutTests {
    private let tolerance: CGFloat = 0.000_001

    @Test func portraitFitReservesDockHeightAndMaximizesVideo() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let layout = MirrorLayout.fit(videoSize: CGSize(width: 1080, height: 2400), in: screen)
        #expect(abs(layout.video.height - 780) < tolerance)
        #expect(abs(layout.video.width / layout.video.height - 1080.0 / 2400) < tolerance)
        #expect(abs(layout.total.minY - 24) < tolerance)
        #expect(abs(layout.total.maxY - 876) < tolerance)
        #expect(abs(layout.total.midX - screen.midX) < tolerance)
        expectDockGeometry(layout)
    }

    @Test func landscapeFitUsesAvailableWidthWithoutClippingDock() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let layout = MirrorLayout.fit(videoSize: CGSize(width: 2400, height: 1080), in: screen)
        #expect(abs(layout.video.width - 1392) < tolerance)
        #expect(abs(layout.video.height / layout.video.width - 1080.0 / 2400) < tolerance)
        #expect(screen.insetBy(dx: 24, dy: 24).contains(layout.total))
        #expect(abs(layout.total.midY - screen.midY) < tolerance)
        expectDockGeometry(layout)
    }

    @Test func fitSupportsDisplaysLeftOfAndBelowMainDisplay() {
        let screen = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let layout = MirrorLayout.fit(videoSize: CGSize(width: 1080, height: 2424), in: screen)
        let safe = screen.insetBy(dx: 24, dy: 24)
        #expect(safe.contains(layout.total))
        #expect(abs(layout.total.midX - safe.midX) < tolerance)
        #expect(abs(layout.total.midY - safe.midY) < tolerance)
        #expect(abs(layout.video.width / layout.video.height - 1080.0 / 2424) < tolerance)
        expectDockGeometry(layout)
    }

    @Test func constrainNearBottomTranslatesWithoutShrinking() {
        let initial = CGRect(x: 450, y: -5, width: 300, height: 667)
        let layout = MirrorLayout.constrain(videoFrame: initial, in: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(layout.video.size == initial.size)
        #expect(layout.video.minX == initial.minX)
        #expect(abs(layout.controls.minY - 8) < tolerance)
        #expect(abs(layout.video.minY - 80) < tolerance)
        expectDockGeometry(layout)
    }

    @Test func constrainOffscreenOnNegativeDisplayUsesScreenCoordinates() {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let initial = CGRect(x: -2200, y: 150, width: 300, height: 500)
        let layout = MirrorLayout.constrain(videoFrame: initial, in: screen)
        #expect(layout.video.size == initial.size)
        #expect(abs(layout.total.minX - (screen.minX + 8)) < tolerance)
        #expect(layout.video.minY == initial.minY)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(layout.total))
        expectDockGeometry(layout)
    }

    @Test func constrainLeavesAlreadyValidPlacementUnchanged() {
        let initial = CGRect(x: 500, y: 180, width: 300, height: 600)
        let layout = MirrorLayout.constrain(videoFrame: initial, in: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(layout.video == initial)
        expectDockGeometry(layout)
    }

    @Test(arguments: [CGSize(width: 900, height: 1800), CGSize(width: 2500, height: 800)])
    func oversizedVideoShrinksUniformlyAndKeepsWholeAssemblyVisible(size: CGSize) {
        let screen = CGRect(x: -600, y: 200, width: 600, height: 500)
        let layout = MirrorLayout.constrain(videoFrame: CGRect(origin: CGPoint(x: 300, y: -500), size: size), in: screen)
        #expect(layout.video.width < size.width)
        #expect(layout.video.height < size.height)
        #expect(abs(layout.video.width / layout.video.height - size.width / size.height) < tolerance)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(layout.total))
        expectDockGeometry(layout)
    }

    @Test func dockWiderThanPhoneIsIncludedWhenConstraining() {
        let initial = CGRect(x: 0, y: 200, width: 100, height: 300)
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let layout = MirrorLayout.constrain(videoFrame: initial, in: screen)
        #expect(layout.video.size == initial.size)
        #expect(abs(layout.controls.minX - 8) < tolerance)
        #expect(layout.video.minX > 8)
        #expect(abs(layout.resizeHandle.maxX - layout.controls.maxX) < tolerance)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(layout.total))
        expectDockGeometry(layout)
    }

    @Test func narrowPortraitFitCentersTheDockAndBothHandlesTogether() {
        let screen = CGRect(x: -520, y: 0, width: 520, height: 900)
        let layout = MirrorLayout.fit(videoSize: CGSize(width: 100, height: 1000), in: screen)
        #expect(layout.video.width < layout.controls.width)
        #expect(abs(layout.total.width - 376) < tolerance)
        #expect(abs(layout.total.midX - screen.midX) < tolerance)
        #expect(screen.insetBy(dx: 24, dy: 24).contains(layout.total))
        expectDockGeometry(layout)
    }

    @Test func rightEdgeKeepsResizeHandleAccessibleWithoutShrinkingPhone() {
        let initial = CGRect(x: 550, y: 180, width: 300, height: 600)
        let screen = CGRect(x: 0, y: 0, width: 800, height: 900)
        let layout = MirrorLayout.constrain(videoFrame: initial, in: screen)
        #expect(layout.video.size == initial.size)
        #expect(abs(layout.resizeHandle.maxX - 792) < tolerance)
        #expect(abs(layout.video.minX - 454) < tolerance)
        #expect(layout.video.minY == initial.minY)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(layout.total))
        expectDockGeometry(layout)
    }

    @Test func framesInitializerDerivesSymmetricHandlesWithinControls() {
        let video = CGRect(x: 200, y: 300, width: 100, height: 500)
        let controls = CGRect(x: 62, y: 228, width: 376, height: 56)
        let layout = MirrorFrames(video: video, controls: controls)
        #expect(layout.dock == CGRect(x: 102, y: 228, width: 296, height: 56))
        #expect(layout.moveHandle == CGRect(x: 62, y: 240, width: 32, height: 32))
        #expect(layout.resizeHandle == CGRect(x: 406, y: 240, width: 32, height: 32))
        #expect(layout.total.maxX == 438)
        expectDockGeometry(layout)
    }

    @Test func landscapeAtRightEdgeNeedsNoSpaceBeyondTheControlFootprint() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = CGRect(x: 600, y: 260, width: 832, height: 374.4)
        let layout = MirrorLayout.constrain(videoFrame: initial, in: screen)
        #expect(layout.video == initial)
        #expect(layout.total.maxX == 1432)
        #expect(layout.controls.maxX < layout.video.maxX)
        expectDockGeometry(layout)
    }

    @Test func constrainingTwiceDoesNotCauseWindowDrift() {
        let screen = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
        let a = MirrorLayout.constrain(videoFrame: CGRect(x: -2250, y: -400, width: 700, height: 1600), in: screen)
        let b = MirrorLayout.constrain(videoFrame: a.video, in: screen)
        #expect(abs(a.video.minX - b.video.minX) < tolerance)
        #expect(abs(a.video.minY - b.video.minY) < tolerance)
        #expect(abs(a.video.width - b.video.width) < tolerance)
        #expect(abs(a.video.height - b.video.height) < tolerance)
        #expect(abs(a.controls.minY - b.controls.minY) < tolerance)
    }

    @Test func degenerateInputsReturnFiniteGeometryAndExactDockSize() {
        let screens: [CGRect] = [.zero, .null, .infinite,
                                 CGRect(x: -50, y: -50, width: 100, height: 50),
                                 CGRect(x: 0, y: 0, width: 300, height: 500)]
        let sizes: [CGSize] = [.zero, CGSize(width: CGFloat.nan, height: 600),
                               CGSize(width: 300, height: CGFloat.infinity),
                               CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1)]
        for screen in screens {
            for size in sizes {
                let fit = MirrorLayout.fit(videoSize: size, in: screen, inset: .infinity)
                let constrained = MirrorLayout.constrain(videoFrame: CGRect(origin: CGPoint(x: CGFloat.nan, y: 0), size: size), in: screen)
                for layout in [fit, constrained] {
                    #expect(isFinite(layout.video))
                    #expect(isFinite(layout.controls))
                    #expect(isFinite(layout.dock))
                    #expect(isFinite(layout.moveHandle))
                    #expect(isFinite(layout.resizeHandle))
                    #expect(layout.controls.size == CGSize(width: 376, height: 56))
                    #expect(layout.dock.size == CGSize(width: 296, height: 56))
                    #expect(layout.moveHandle.size == CGSize(width: 32, height: 32))
                    #expect(layout.resizeHandle.size == CGSize(width: 32, height: 32))
                }
            }
        }
    }

    private func expectDockGeometry(_ layout: MirrorFrames) {
        #expect(layout.controls.size == CGSize(width: 376, height: 56))
        #expect(abs(layout.controls.midX - layout.video.midX) < tolerance)
        #expect(abs(layout.video.minY - layout.controls.maxY - 16) < tolerance)
        #expect(!layout.video.intersects(layout.controls))
        #expect(layout.dock.size == CGSize(width: 296, height: 56))
        #expect(abs(layout.dock.midX - layout.controls.midX) < tolerance)
        #expect(abs(layout.dock.midY - layout.controls.midY) < tolerance)
        #expect(layout.moveHandle.size == CGSize(width: 32, height: 32))
        #expect(layout.resizeHandle.size == CGSize(width: 32, height: 32))
        #expect(abs(layout.dock.minX - layout.moveHandle.maxX - 8) < tolerance)
        #expect(abs(layout.resizeHandle.minX - layout.dock.maxX - 8) < tolerance)
        #expect(abs(layout.moveHandle.midY - layout.controls.midY) < tolerance)
        #expect(abs(layout.resizeHandle.midY - layout.controls.midY) < tolerance)
        #expect(layout.controls.contains(layout.moveHandle))
        #expect(layout.controls.contains(layout.resizeHandle))
        #expect(!layout.moveHandle.intersects(layout.dock))
        #expect(!layout.resizeHandle.intersects(layout.dock))
        #expect(!layout.moveHandle.intersects(layout.video))
        #expect(!layout.resizeHandle.intersects(layout.video))
        #expect(layout.total == layout.video.union(layout.controls))
    }

    private func isFinite(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height, rect.minX, rect.maxX, rect.minY, rect.maxY].allSatisfy(\.isFinite)
    }
}

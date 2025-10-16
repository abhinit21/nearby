import CoreGraphics
import Testing
@testable import NearbyCore

@Suite struct SharingPanelLayoutTests {
    @Test func firstOpenBesideRightEdgeMovesTheWholePanelInsideVisibleBounds() {
        let screen = CGRect(x: 0, y: 30, width: 1440, height: 850)
        // Mirror ends near the right edge; the preferred 24-point offset can
        // place almost the entire independently titled sharing panel outside.
        let proposed = CGRect(x: 1394, y: 190, width: 424, height: 638)
        let result = SharingPanelLayout.reachableFrame(proposed, in: [screen])
        #expect(screen.contains(result))
        #expect(result.size == proposed.size)
        #expect(result.minX == screen.maxX - proposed.width)
        #expect(result.minY == proposed.minY)
    }

    @Test func removedDisplayRestorationFallsBackToTheMirrorsCurrentScreen() {
        let main = CGRect(x: 0, y: 30, width: 1440, height: 850)
        let mirrorScreen = CGRect(x: -1920, y: -200, width: 1920, height: 1050)
        let removedDisplay = CGRect(x: 3100, y: 200, width: 424, height: 638)
        let result = SharingPanelLayout.reachableFrame(removedDisplay, in: [main, mirrorScreen], fallback: mirrorScreen)
        #expect(mirrorScreen.contains(result))
        #expect(result.size == removedDisplay.size)
        #expect(result.minY == removedDisplay.minY)
    }

    @Test func validSavedPlacementOnNegativeOriginDisplayRemainsExactlyUnchanged() {
        let left = CGRect(x: -1920, y: -180, width: 1920, height: 1050)
        let main = CGRect(x: 0, y: 30, width: 1440, height: 850)
        let saved = CGRect(x: -1532.5, y: -44.25, width: 600, height: 720)
        #expect(SharingPanelLayout.reachableFrame(saved, in: [main, left], fallback: main) == saved)
    }

    @Test func oversizedActualFrameShrinksOnlyAsMuchAsNecessaryIncludingTitleBar() {
        let screen = CGRect(x: 150, y: -500, width: 800, height: 560)
        let actualFrame = CGRect(x: 220, y: -540, width: 424, height: 638)
        let result = SharingPanelLayout.reachableFrame(actualFrame, in: [screen])
        #expect(screen.contains(result))
        #expect(result.width == actualFrame.width)
        #expect(result.height == screen.height)
        #expect(result.minX == actualFrame.minX)
        #expect(result.minY == screen.minY)
    }

    @Test func oversizedWidthAndHeightFitSmallVisibleFrame() {
        let screen = CGRect(x: -300, y: 200, width: 360, height: 420)
        let saved = CGRect(x: -400, y: 100, width: 600, height: 720)
        #expect(SharingPanelLayout.reachableFrame(saved, in: [screen]) == screen)
    }

    @Test func validSavedSizeAndPositionArePreservedOnEveryShow() {
        let screen = CGRect(x: 0, y: 30, width: 1440, height: 850)
        let saved = CGRect(x: 216.5, y: 80.25, width: 680, height: 760)
        #expect(SharingPanelLayout.reachableFrame(saved, in: [screen], fallback: screen) == saved)
    }

    @Test func largestCurrentScreenIntersectionWinsOverFallback() {
        let left = CGRect(x: -1200, y: 30, width: 1200, height: 850)
        let main = CGRect(x: 0, y: 30, width: 1440, height: 850)
        let straddling = CGRect(x: -100, y: 120, width: 424, height: 638)
        let result = SharingPanelLayout.reachableFrame(straddling, in: [left, main], fallback: left)
        #expect(main.contains(result))
        #expect(result.minX == main.minX)
        #expect(result.size == straddling.size)
    }

    @Test func repeatedShowIsIdempotentAndNeverSelectsARemovedFallback() {
        let screens = [CGRect(x: -1920, y: -180, width: 1920, height: 1050),
                       CGRect(x: 0, y: 30, width: 1440, height: 850)]
        let removed = CGRect(x: 4000, y: 0, width: 1920, height: 1080)
        let first = SharingPanelLayout.reachableFrame(CGRect(x: 5000, y: -900, width: 700, height: 1400), in: screens, fallback: removed)
        let second = SharingPanelLayout.reachableFrame(first, in: screens, fallback: removed)
        #expect(first == second)
        #expect(screens[0].contains(first))
    }
}

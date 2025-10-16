import CoreGraphics

/// Pure geometry for the dock's right resize grip. Screen Y increases
/// upward; the original video's top-left stays anchored whenever the assembly fits.
public enum MirrorResizeGesture {
    public static func frames(startFrame: CGRect, mouseDown: CGPoint, mouseDragged: CGPoint,
                              in visibleFrame: CGRect, minimumSize: CGSize) -> MirrorFrames {
        let unchanged = MirrorLayout.constrain(videoFrame: startFrame, in: visibleFrame)
        guard isFinite(startFrame), startFrame.width > 0, startFrame.height > 0,
              isFinite(visibleFrame), visibleFrame.width > 0, visibleFrame.height > 0,
              mouseDown.x.isFinite, mouseDown.y.isFinite,
              mouseDragged.x.isFinite, mouseDragged.y.isFinite else { return unchanged }
        let ratio = startFrame.width / startFrame.height
        guard ratio.isFinite, ratio > 0 else { return unchanged }

        // This is (dx * ratio - dy) / (ratio² + 1), expressed with
        // a normalized diagonal so extreme aspect ratios cannot overflow ratio².
        let longest = max(startFrame.width, startFrame.height)
        let unitX = startFrame.width / longest, unitY = startFrame.height / longest
        let dx = boundedDifference(mouseDragged.x, mouseDown.x)
        let dy = boundedDifference(mouseDragged.y, mouseDown.y)
        let projection = (dx * unitX - dy * unitY) / (unitX * unitX + unitY * unitY)
        let deltaHeight = projection * unitY

        let inset: CGFloat = 8 // MirrorLayout.constrain's ordinary screen margin.
        let bounds = visibleFrame.standardized
        let dockSpan = MirrorLayout.gap + MirrorLayout.controlSize.height
        let rightSpace = max(0, bounds.maxX - inset - startFrame.minX)
        // The dock is centered under the video. Both its right edge and the
        // video's right edge must remain within the display's visible frame.
        let widthLimit = max(0, rightSpace - max(0, MirrorLayout.controlSize.width - rightSpace))
        let heightLimit = max(0, startFrame.maxY - bounds.minY - inset - dockSpan)
        let maximumHeight = min(heightLimit, widthLimit / ratio)
        guard maximumHeight.isFinite, maximumHeight > 0 else { return unchanged }

        let minWidth = minimumSize.width.isFinite ? max(0, minimumSize.width) : 0
        let minHeight = minimumSize.height.isFinite ? max(0, minimumSize.height) : 0
        let requestedMinimum = max(minHeight, minWidth / ratio)
        // A display too small for the requested minimum takes precedence over
        // minimum size; final layout must keep the whole assembly reachable.
        let minimumHeight = min(maximumHeight, requestedMinimum)
        let requested = startFrame.height + deltaHeight
        let height: CGFloat
        if requested.isFinite {
            height = min(max(requested, minimumHeight), maximumHeight)
        } else {
            height = deltaHeight > 0 ? maximumHeight : minimumHeight
        }
        let candidate = CGRect(x: startFrame.minX, y: startFrame.maxY - height,
                               width: height * ratio, height: height)
        return MirrorLayout.constrain(videoFrame: candidate, in: visibleFrame)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.minX.isFinite && rect.maxX.isFinite && rect.minY.isFinite && rect.maxY.isFinite
    }

    private static func boundedDifference(_ value: CGFloat, _ start: CGFloat) -> CGFloat {
        // Even subtraction of two finite screen points can overflow. Saturation
        // preserves drag direction while leaving headroom for the dot product.
        let limit = CGFloat.greatestFiniteMagnitude / 4
        let difference = value - start
        if difference.isFinite { return min(max(difference, -limit), limit) }
        return value >= start ? limit : -limit
    }
}

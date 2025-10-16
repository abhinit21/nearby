import CoreGraphics

/// Frames in AppKit screen coordinates, where increasing Y moves upward.
public struct MirrorFrames: Equatable, Sendable {
    public let video: CGRect
    /// Stable transparent footprint containing the glass dock and both handles.
    public let controls: CGRect

    public init(video: CGRect, controls: CGRect) {
        self.video = video
        self.controls = controls
    }

    public var dock: CGRect { MirrorLayout.dockFrame(in: controls) }
    public var moveHandle: CGRect { MirrorLayout.moveHandleFrame(in: controls) }
    public var resizeHandle: CGRect { MirrorLayout.resizeHandleFrame(in: controls) }
    public var total: CGRect { video.union(controls) }
}

/// Positions the glass controls outside the phone's video and touch area.
public enum MirrorLayout {
    public static let controlSize = CGSize(width: 376, height: 56)
    public static let dockSize = CGSize(width: 296, height: 56)
    public static let gap: CGFloat = 16
    public static let resizeHandleSize = CGSize(width: 32, height: 32)
    public static let resizeHandleGap: CGFloat = 8

    /// The glass is centered in a stable footprint so revealing either handle
    /// does not shift the dock, its buttons, or the mirror.
    public static func dockFrame(in controls: CGRect) -> CGRect {
        CGRect(x: controls.midX - dockSize.width / 2,
               y: controls.midY - dockSize.height / 2,
               width: dockSize.width, height: dockSize.height)
    }

    public static func moveHandleFrame(in controls: CGRect) -> CGRect {
        let dock = dockFrame(in: controls)
        return CGRect(x: dock.minX - resizeHandleGap - resizeHandleSize.width,
                      y: controls.midY - resizeHandleSize.height / 2,
                      width: resizeHandleSize.width, height: resizeHandleSize.height)
    }

    public static func resizeHandleFrame(in controls: CGRect) -> CGRect {
        let dock = dockFrame(in: controls)
        return CGRect(x: dock.maxX + resizeHandleGap,
                      y: controls.midY - resizeHandleSize.height / 2,
                      width: resizeHandleSize.width, height: resizeHandleSize.height)
    }

    /// Maximizes the video while reserving room below it for the controls.
    public static func fit(videoSize: CGSize, in visibleFrame: CGRect, inset: CGFloat = 24) -> MirrorFrames {
        let bounds = usableBounds(visibleFrame, inset: inset)
        let size = fittedVideoSize(videoSize, bounds: bounds, allowGrowth: true)
        let video = CGRect(x: bounds.midX - size.width / 2,
                           y: bounds.midY - (size.height + dockSpan) / 2 + dockSpan,
                           width: size.width, height: size.height)
        return frames(for: video)
    }

    /// Preserves an existing video's size and location whenever possible. If the
    /// combined video and dock do not fit, shrinks the video uniformly, then
    /// makes the smallest translation needed to keep both windows on screen.
    public static func constrain(videoFrame: CGRect, in visibleFrame: CGRect, inset: CGFloat = 8) -> MirrorFrames {
        let bounds = usableBounds(visibleFrame, inset: inset)
        let original = finiteStandardizedRect(videoFrame) ?? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        let sourceSize = validVideoSize(original.size)
        let size = fittedVideoSize(sourceSize, bounds: bounds, allowGrowth: false)
        let totalWidth = max(size.width, controlSize.width)
        let totalHeight = size.height + dockSpan
        let centerX = constrainedCenter(original.midX, length: totalWidth,
                                        lower: bounds.minX, upper: bounds.maxX)
        let centerY = constrainedCenter(original.midY - dockSpan / 2, length: totalHeight,
                                        lower: bounds.minY, upper: bounds.maxY)
        let video = CGRect(x: centerX - size.width / 2,
                           y: centerY - totalHeight / 2 + dockSpan,
                           width: size.width, height: size.height)
        return frames(for: video)
    }

    private static var dockSpan: CGFloat { controlSize.height + gap }

    private static func frames(for video: CGRect) -> MirrorFrames {
        MirrorFrames(video: video,
                     controls: CGRect(x: video.midX - controlSize.width / 2,
                                      y: video.minY - dockSpan,
                                      width: controlSize.width, height: controlSize.height))
    }

    private static func usableBounds(_ visibleFrame: CGRect, inset: CGFloat) -> CGRect {
        let screen = finiteStandardizedRect(visibleFrame) ?? .zero
        let requested = inset.isFinite ? max(0, inset) : 0
        // Preserve the requested margin on ordinary screens. If a very small
        // screen cannot accommodate it, reduce the margin before reducing video.
        let dx = min(requested, max(0, (screen.width - controlSize.width) / 2))
        let dy = min(requested, max(0, (screen.height - dockSpan) / 2))
        return screen.insetBy(dx: dx, dy: dy)
    }

    private static func fittedVideoSize(_ source: CGSize, bounds: CGRect, allowGrowth: Bool) -> CGSize {
        let size = validVideoSize(source)
        let longest = max(size.width, size.height)
        // Normalize before scaling so extremely large or small input dimensions
        // cannot produce infinity through an intermediate ratio or product.
        let unit = CGSize(width: size.width / longest, height: size.height / longest)
        let availableWidth = max(0, bounds.width)
        let widthLimit = unit.width > 0 ? availableWidth / unit.width : .infinity
        let availableHeight = max(0, bounds.height - dockSpan)
        let heightLimit = unit.height > 0 ? availableHeight / unit.height : .infinity
        let limit = min(widthLimit, heightLimit)
        let scale = allowGrowth ? limit : min(longest, limit)
        return CGSize(width: unit.width * scale, height: unit.height * scale)
    }

    private static func validVideoSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        return size
    }

    private static func finiteStandardizedRect(_ rect: CGRect) -> CGRect? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        let result = rect.standardized
        guard result.minX.isFinite, result.maxX.isFinite,
              result.minY.isFinite, result.maxY.isFinite else { return nil }
        return result
    }

    private static func constrainedCenter(_ desired: CGFloat, length: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        let available = upper - lower
        // Exact dock size cannot fit an impossibly small screen. Keep the result
        // finite and centered in that case rather than manufacturing NaN geometry.
        if length > available { return lower + available / 2 }
        return min(max(desired, lower + length / 2), upper - length / 2)
    }
}

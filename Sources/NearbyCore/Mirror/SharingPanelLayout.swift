import CoreGraphics

/// Keeps the complete sharing window, including its title bar, reachable after
/// restoration or display changes. Coordinates use AppKit's upward Y axis.
public enum SharingPanelLayout {
    public static func reachableFrame(_ frame: CGRect, in visibleFrames: [CGRect], fallback: CGRect? = nil) -> CGRect {
        let screens = visibleFrames.compactMap(validRect)
        let original = validRect(frame)
        guard !screens.isEmpty else { return original ?? .zero }

        var selected: CGRect?
        var largestIntersection: CGFloat = 0
        if let original {
            for screen in screens {
                let intersection = original.intersection(screen)
                guard !intersection.isNull, !intersection.isEmpty else { continue }
                let area = intersection.width * intersection.height
                if area > largestIntersection { selected = screen; largestIntersection = area }
            }
        }
        if selected == nil, let fallback = fallback.flatMap(validRect), screens.contains(fallback) { selected = fallback }
        let bounds = selected ?? screens[0]
        guard let original else { return bounds }
        if bounds.contains(original) { return original }

        let size = CGSize(width: min(original.width, bounds.width), height: min(original.height, bounds.height))
        return CGRect(x: min(max(original.minX, bounds.minX), bounds.maxX - size.width),
                      y: min(max(original.minY, bounds.minY), bounds.maxY - size.height),
                      width: size.width, height: size.height)
    }

    private static func validRect(_ rect: CGRect) -> CGRect? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        let normalized = rect.standardized
        guard !normalized.isEmpty, normalized.maxX.isFinite, normalized.maxY.isFinite else { return nil }
        return normalized
    }
}

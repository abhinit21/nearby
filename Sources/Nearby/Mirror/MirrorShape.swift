import CoreGraphics
import SwiftUI

/// A proportional continuous rectangle, independent of the phone's hardware.
/// Sharing the path keeps visible corners and pointer containment in agreement.
enum MirrorShape {
    static let cornerRatio: CGFloat = 0.10

    static func cornerRadius(in bounds: CGRect) -> CGFloat {
        guard !bounds.isNull, !bounds.isInfinite,
              bounds.size.width.isFinite, bounds.size.height.isFinite,
              bounds.size.width > 0, bounds.size.height > 0 else { return 0 }
        return min(bounds.width, bounds.height) * cornerRatio
    }

    static func path(in bounds: CGRect) -> CGPath {
        guard !bounds.isNull, !bounds.isInfinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.size.width.isFinite, bounds.size.height.isFinite,
              bounds.size.width > 0, bounds.size.height > 0,
              bounds.maxX.isFinite, bounds.maxY.isFinite else {
            return CGMutablePath()
        }
        return RoundedRectangle(cornerRadius: cornerRadius(in: bounds), style: .continuous)
            .path(in: bounds).cgPath
    }
}

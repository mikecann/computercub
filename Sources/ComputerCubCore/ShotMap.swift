import CoreGraphics
import Foundation

// Turns a spot in a window's last `shot` into a point in the window. Agents read positions
// off the picture, whose pixels aren't the window's points: it's 2x on a Retina display,
// shrunk to fit --max, and may be cropped to one element or widened for an open menu.
public struct ShotMap {
    public let origin: CGPoint  // the picture's top-left, in points from the window's
    public let scale: CGFloat  // picture pixels per point
    public let size: CGSize  // the picture, in pixels
    public let windowSize: CGSize  // the window when it was taken, in points

    public init(origin: CGPoint, scale: CGFloat, size: CGSize, windowSize: CGSize) {
        self.origin = origin
        self.scale = scale
        self.size = size
        self.windowSize = windowSize
    }

    public func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(x) / scale, y: origin.y + CGFloat(y) / scale)
    }

    public func inPicture(x: Double, y: Double) -> Bool {
        x >= 0 && y >= 0 && CGFloat(x) < size.width && CGFloat(y) < size.height
    }

    public func inWindow(_ p: CGPoint) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x < windowSize.width && p.y < windowSize.height
    }

    // A resize moves everything in the picture, though a move doesn't: points are relative
    // to the window. Within a point, as AX frames can come back fractional.
    public func stale(windowSize now: CGSize) -> Bool {
        abs(now.width - windowSize.width) > 1 || abs(now.height - windowSize.height) > 1
    }
}

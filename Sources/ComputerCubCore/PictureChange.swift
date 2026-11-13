import CoreGraphics

// Whether a scroll did anything, from two small greyscale pictures of a window (one byte
// a pixel, `width` across). More than a sliver has to change: a clock ticking over or a
// cursor blinking shouldn't count. `part` (fractions of the picture, 0 to 1) narrows it
// to one spot, such as a small list in a big window that would otherwise be under the sliver.
public enum PictureChange {
    public static func moved(_ a: [UInt8], _ b: [UInt8], width: Int, part: CGRect? = nil) -> Bool {
        guard a.count == b.count, !a.isEmpty, width > 0 else { return a != b }
        var idx = Array(a.indices)
        if let part {
            let height = a.count / width
            let x0 = max(0, Int(part.minX * Double(width))), x1 = min(width, max(x0 + 1, Int((part.maxX * Double(width)).rounded(.up))))
            let y0 = max(0, Int(part.minY * Double(height))), y1 = min(height, max(y0 + 1, Int((part.maxY * Double(height)).rounded(.up))))
            let spot = x0 < x1 && y0 < y1 ? (y0..<y1).flatMap { y in (x0..<x1).map { y * width + $0 } } : []
            if !spot.isEmpty { idx = spot }
        }
        let changed = idx.filter { abs(Int(a[$0]) - Int(b[$0])) > 24 }.count
        return Double(changed) / Double(idx.count) > 0.03
    }
}

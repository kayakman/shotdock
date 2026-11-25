import CoreGraphics

public extension CGRect {
    /// The rectangle spanned by two corner points, in any order.
    init(corner a: CGPoint, corner b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Rounded outwards to whole units, so a selection never cuts a pixel.
    var pixelAligned: CGRect {
        let minX = floor(self.minX), minY = floor(self.minY)
        return CGRect(x: minX, y: minY, width: ceil(maxX) - minX, height: ceil(maxY) - minY)
    }
}

public extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(other.x - x, other.y - y) }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }

    /// Distance from this point to the segment `a`–`b`.
    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / lengthSquared))
        return distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

import AppKit
import ShotDockCore

/// The magnifier: a grid of enlarged pixels around a point, with its
/// coordinates and colour underneath. Drawn in any top-left-origin context;
/// `unit` is how many user-space units make one screen point.
enum Loupe {
    static let cells = 15
    static let cellSize: CGFloat = 8
    static var side: CGFloat { CGFloat(cells) * cellSize }

    /// Total size in screen points, label included.
    static var size: CGSize { CGSize(width: side, height: side + 26) }

    /// Puts the loupe beside `point`, flipping sides near the edges of `bounds`.
    static func origin(near point: CGPoint, in bounds: CGRect, unit: CGFloat) -> CGPoint {
        let w = size.width * unit, h = size.height * unit, gap = 24 * unit
        var x = point.x + gap, y = point.y + gap
        if x + w > bounds.maxX { x = point.x - gap - w }
        if y + h > bounds.maxY { y = point.y - gap - h }
        return CGPoint(x: max(bounds.minX, x), y: max(bounds.minY, y))
    }

    static func draw(image: CGImage, pixel: CGPoint, at origin: CGPoint, unit: CGFloat,
                     colorFormat: ColorFormat, in context: CGContext) {
        let px = Int(pixel.x), py = Int(pixel.y)
        let half = cells / 2
        let side = self.side * unit
        let frame = CGRect(x: origin.x, y: origin.y, width: side, height: side)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2 * unit), blur: 8 * unit, color: CGColor(gray: 0, alpha: 0.5))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(frame)
        context.restoreGState()

        // Enlarged pixels, nearest-neighbour; out-of-image cells stay dark.
        let source = CGRect(x: px - half, y: py - half, width: cells, height: cells)
        let visible = source.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !visible.isNull, let crop = image.cropping(to: visible) {
            let cell = cellSize * unit
            let target = CGRect(x: frame.minX + (visible.minX - source.minX) * cell,
                                y: frame.minY + (visible.minY - source.minY) * cell,
                                width: visible.width * cell, height: visible.height * cell)
            context.saveGState()
            context.interpolationQuality = .none
            context.clip(to: frame)
            context.drawImageTopLeft(crop, in: target)
            context.restoreGState()
        }

        // Pixel grid and the centre cell.
        let cell = cellSize * unit
        context.setStrokeColor(CGColor(gray: 0.5, alpha: 0.25))
        context.setLineWidth(0.5 * unit)
        for i in 1..<cells {
            let offset = CGFloat(i) * cell
            context.strokeLineSegments(between: [CGPoint(x: frame.minX + offset, y: frame.minY), CGPoint(x: frame.minX + offset, y: frame.maxY),
                                                 CGPoint(x: frame.minX, y: frame.minY + offset), CGPoint(x: frame.maxX, y: frame.minY + offset)])
        }
        let center = CGRect(x: frame.minX + CGFloat(half) * cell, y: frame.minY + CGFloat(half) * cell, width: cell, height: cell)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(2.5 * unit)
        context.stroke(center)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1.2 * unit)
        context.stroke(center)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setLineWidth(2 * unit)
        context.stroke(frame)

        // Label: coordinates and colour.
        let color = Measure.color(in: image, at: pixel)
        let text = "\(px), \(py)" + (color.map { "  " + colorFormat.string(for: $0) } ?? "")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * unit, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let label = CGRect(x: frame.minX, y: frame.maxY + 4 * unit, width: side, height: 20 * unit)
        context.setFillColor(CGColor(gray: 0, alpha: 0.75))
        context.addPath(CGPath(roundedRect: label, cornerWidth: 5 * unit, cornerHeight: 5 * unit, transform: nil))
        context.fillPath()
        if let color {
            let swatch = CGRect(x: label.minX + 5 * unit, y: label.minY + 5 * unit, width: 10 * unit, height: 10 * unit)
            context.setFillColor(color.cgColor)
            context.fill(swatch)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
            context.setLineWidth(1 * unit)
            context.stroke(swatch)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        (text as NSString).draw(at: CGPoint(x: label.minX + 20 * unit, y: label.minY + 3 * unit), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}

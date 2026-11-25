import CoreGraphics
import Foundation

/// The pixel ruler: from a point, how far the same colour extends in each
/// direction. That is the size of the button, gap or box under the pointer.
public struct EdgeMeasurement: Equatable, Sendable {
    /// Pixels of the same colour to each side, not counting the start pixel.
    public var left: Int
    public var right: Int
    public var up: Int
    public var down: Int

    public var width: Int { left + right + 1 }
    public var height: Int { up + down + 1 }

    /// The measured region, in image pixels (top-left origin).
    public func rect(around point: CGPoint) -> CGRect {
        CGRect(x: floor(point.x) - CGFloat(left), y: floor(point.y) - CGFloat(up), width: CGFloat(width), height: CGFloat(height))
    }
}

public enum Measure {
    /// Scans from `point` until a pixel differs from the start pixel by more
    /// than `tolerance` (0–255 on any channel), or the image ends.
    public static func edges(in image: CGImage, at point: CGPoint, tolerance: Int = 24) -> EdgeMeasurement? {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        // Only the row and the column through the point are needed.
        guard let row = PixelBuffer(image: image, rect: CGRect(x: 0, y: y, width: image.width, height: 1)),
              let column = PixelBuffer(image: image, rect: CGRect(x: x, y: 0, width: 1, height: image.height)) else { return nil }
        let start = row.pixel(x, 0)
        let limit = Float(tolerance)
        func same(_ p: SIMD4<Float>) -> Bool {
            let d = p - start
            return max(abs(d.x), abs(d.y), abs(d.z)) <= limit
        }
        func run(_ count: Int, _ sample: (Int) -> SIMD4<Float>) -> Int {
            var n = 0
            while n < count, same(sample(n + 1)) { n += 1 }
            return n
        }
        return EdgeMeasurement(
            left: run(x) { row.pixel(x - $0, 0) },
            right: run(image.width - 1 - x) { row.pixel(x + $0, 0) },
            up: run(y) { column.pixel(0, y - $0) },
            down: run(image.height - 1 - y) { column.pixel(0, y + $0) })
    }

    /// Colour of one pixel, or nil outside the image.
    public static func color(in image: CGImage, at point: CGPoint) -> RGBAColor? {
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let buffer = PixelBuffer(image: image, rect: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        let p = buffer.pixel(0, 0)
        return RGBAColor(red: Double(p.x) / 255, green: Double(p.y) / 255, blue: Double(p.z) / 255, alpha: Double(p.w) / 255)
    }
}

public enum ColorFormat: String, CaseIterable, Codable, Sendable {
    case hex, rgb

    public func string(for color: RGBAColor) -> String {
        let r = Int((color.red * 255).rounded()), g = Int((color.green * 255).rounded()), b = Int((color.blue * 255).rounded())
        switch self {
        case .hex: return String(format: "#%02X%02X%02X", r, g, b)
        case .rgb: return "rgb(\(r), \(g), \(b))"
        }
    }
}

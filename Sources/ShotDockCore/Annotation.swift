import CoreGraphics
import Foundation

public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var color: RGBAColor
    /// Stroke width in image pixels.
    public var lineWidth: CGFloat
    /// Font size in image pixels (also sizes step numbers).
    public var fontSize: CGFloat

    public init(color: RGBAColor = .red, lineWidth: CGFloat = 6, fontSize: CGFloat = 36) {
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
    }
}

public enum AnnotationShape: Codable, Equatable, Sendable {
    case arrow(from: CGPoint, to: CGPoint)
    case rectangle(CGRect)
    case ellipse(CGRect)
    /// Translucent marker over the area.
    case highlight(CGRect)
    /// `origin` is the top-left corner of the text block.
    case text(origin: CGPoint, string: String)
    /// A numbered circle for step-by-step instructions.
    case step(center: CGPoint, number: Int)
    /// Hides what is under the area by blurring the capture.
    case blur(CGRect)
    /// Hides what is under the area with big pixels.
    case pixelate(CGRect)
    /// Paints the area with the background around it (smart eraser).
    case erase(CGRect)
}

/// A vector mark drawn over a capture. Coordinates are image pixels with the
/// origin at the top-left corner.
public struct Annotation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var shape: AnnotationShape
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), shape: AnnotationShape, style: AnnotationStyle) {
        self.id = id
        self.shape = shape
        self.style = style
    }

    /// The rectangle of box-like shapes.
    public var box: CGRect? {
        switch shape {
        case let .rectangle(r), let .ellipse(r), let .highlight(r), let .blur(r), let .pixelate(r), let .erase(r): r
        case .arrow, .text, .step: nil
        }
    }

    public func withBox(_ rect: CGRect) -> Annotation {
        var copy = self
        switch shape {
        case .rectangle: copy.shape = .rectangle(rect)
        case .ellipse: copy.shape = .ellipse(rect)
        case .highlight: copy.shape = .highlight(rect)
        case .blur: copy.shape = .blur(rect)
        case .pixelate: copy.shape = .pixelate(rect)
        case .erase: copy.shape = .erase(rect)
        case .arrow, .text, .step: break
        }
        return copy
    }

    /// Area the annotation paints, including stroke and arrow head.
    public var bounds: CGRect {
        switch shape {
        case let .arrow(from, to):
            return CGRect(corner: from, corner: to).insetBy(dx: -style.arrowHeadLength, dy: -style.arrowHeadLength)
        case let .rectangle(rect), let .ellipse(rect):
            return rect.insetBy(dx: -style.lineWidth / 2, dy: -style.lineWidth / 2)
        case let .highlight(rect), let .blur(rect), let .pixelate(rect), let .erase(rect):
            return rect
        case let .text(origin, string):
            return CGRect(origin: origin, size: TextLayout(string: string, fontSize: style.fontSize).size)
        case let .step(center, _):
            let r = style.stepRadius
            return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        }
    }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        let slack = tolerance + style.lineWidth / 2
        switch shape {
        case let .arrow(from, to):
            return point.distance(toSegment: from, to) <= max(slack, style.arrowHeadLength / 2)
        case let .rectangle(rect):
            let outer = rect.insetBy(dx: -slack, dy: -slack)
            let inner = rect.insetBy(dx: slack, dy: slack)
            return outer.contains(point) && (inner.isNull || inner.isEmpty || !inner.contains(point))
        case let .ellipse(rect):
            let a = rect.width / 2, b = rect.height / 2
            guard a > 0, b > 0 else { return false }
            // Distance to the outline, approximated by scaling the normalised radius.
            let dx = (point.x - rect.midX) / a, dy = (point.y - rect.midY) / b
            let r = (dx * dx + dy * dy).squareRoot()
            return abs(r - 1) * min(a, b) <= slack
        case .highlight, .blur, .pixelate, .erase, .text:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case let .step(center, _):
            return point.distance(to: center) <= style.stepRadius + tolerance
        }
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        var copy = self
        switch shape {
        case let .arrow(from, to):
            copy.shape = .arrow(from: from.offsetBy(dx: dx, dy: dy), to: to.offsetBy(dx: dx, dy: dy))
        case let .text(origin, string):
            copy.shape = .text(origin: origin.offsetBy(dx: dx, dy: dy), string: string)
        case let .step(center, number):
            copy.shape = .step(center: center.offsetBy(dx: dx, dy: dy), number: number)
        default:
            if let box { copy = withBox(box.offsetBy(dx: dx, dy: dy)) }
        }
        return copy
    }

    // MARK: Resize handles

    /// Points the user can drag to reshape: box corners (top-left, top-right,
    /// bottom-right, bottom-left) or arrow ends.
    public var handles: [CGPoint] {
        if case let .arrow(from, to) = shape { return [from, to] }
        guard let box else { return [] }
        return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
    }

    public func movingHandle(_ index: Int, to point: CGPoint) -> Annotation {
        var copy = self
        if case let .arrow(from, to) = shape {
            copy.shape = index == 0 ? .arrow(from: point, to: to) : .arrow(from: from, to: point)
            return copy
        }
        let corners = handles
        guard corners.indices.contains(index) else { return self }
        let opposite = corners[(index + 2) % 4]
        return withBox(CGRect(corner: opposite, corner: point))
    }

    public var isPixelEffect: Bool {
        switch shape {
        case .blur, .pixelate, .erase: true
        default: false
        }
    }

    /// Shapes too small to see (a click without a drag) are discarded.
    public var isDegenerate: Bool {
        switch shape {
        case let .arrow(from, to): from.distance(to: to) < 4
        case let .text(_, string): string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .step: false
        default: (box?.width ?? 0) < 3 || (box?.height ?? 0) < 3
        }
    }
}

extension AnnotationStyle {
    var arrowHeadLength: CGFloat { max(lineWidth * 4.5, 16) }
    public var stepRadius: CGFloat { max(fontSize * 0.7, 10) }
}

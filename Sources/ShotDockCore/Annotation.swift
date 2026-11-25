import CoreGraphics
import Foundation

public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var color: RGBAColor
    /// Stroke width in image pixels.
    public var lineWidth: CGFloat
    /// Font size in image pixels.
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
    /// `origin` is the top-left corner of the text block.
    case text(origin: CGPoint, string: String)
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

    /// Area the annotation paints, including stroke and arrow head.
    public var bounds: CGRect {
        switch shape {
        case let .arrow(from, to):
            return CGRect(corner: from, corner: to).insetBy(dx: -style.arrowHeadLength, dy: -style.arrowHeadLength)
        case let .rectangle(rect):
            return rect.insetBy(dx: -style.lineWidth / 2, dy: -style.lineWidth / 2)
        case let .text(origin, string):
            return CGRect(origin: origin, size: TextLayout(string: string, fontSize: style.fontSize).size)
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
        case .text:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        var copy = self
        switch shape {
        case let .arrow(from, to):
            copy.shape = .arrow(from: from.offsetBy(dx: dx, dy: dy), to: to.offsetBy(dx: dx, dy: dy))
        case let .rectangle(rect):
            copy.shape = .rectangle(rect.offsetBy(dx: dx, dy: dy))
        case let .text(origin, string):
            copy.shape = .text(origin: origin.offsetBy(dx: dx, dy: dy), string: string)
        }
        return copy
    }

    /// Shapes too small to see (a click without a drag) are discarded.
    public var isDegenerate: Bool {
        switch shape {
        case let .arrow(from, to): from.distance(to: to) < 4
        case let .rectangle(rect): rect.width < 3 || rect.height < 3
        case let .text(_, string): string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

extension AnnotationStyle {
    var arrowHeadLength: CGFloat { max(lineWidth * 4.5, 16) }
}

import CoreGraphics
import Foundation

public enum AnnotationRenderer {
    /// Draws annotations into a context whose user space is image pixels with
    /// a top-left origin (a flipped view, or a bitmap after `flip`).
    public static func draw(_ annotations: [Annotation], in context: CGContext) {
        for annotation in annotations { draw(annotation, in: context) }
    }

    public static func draw(_ annotation: Annotation, in context: CGContext) {
        let style = annotation.style
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(style.color.cgColor)
        context.setFillColor(style.color.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.shape {
        case let .arrow(from, to):
            drawArrow(from: from, to: to, style: style, in: context)
        case let .rectangle(rect):
            let radius = min(style.lineWidth, rect.width / 2, rect.height / 2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        case let .text(origin, string):
            TextLayout(string: string, fontSize: style.fontSize, color: style.color.cgColor).draw(at: origin, in: context)
        }
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, style: AnnotationStyle, in context: CGContext) {
        let length = from.distance(to: to)
        guard length > 0 else { return }
        let ux = (to.x - from.x) / length, uy = (to.y - from.y) / length
        let headLength = min(style.arrowHeadLength, length)
        let halfWidth = headLength * 0.6
        let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)
        // The shaft stops inside the head so its round cap never pokes out of the tip.
        let shaftEnd = CGPoint(x: to.x - ux * headLength * 0.7, y: to.y - uy * headLength * 0.7)

        context.move(to: from)
        context.addLine(to: shaftEnd)
        context.strokePath()

        context.move(to: to)
        context.addLine(to: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth))
        context.addLine(to: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth))
        context.closePath()
        context.fillPath()
    }
}

public extension CGContext {
    /// Switches a bottom-left-origin bitmap context to top-left-origin coordinates.
    func flipVertically(height: CGFloat) {
        translateBy(x: 0, y: height)
        scaleBy(x: 1, y: -1)
    }
}

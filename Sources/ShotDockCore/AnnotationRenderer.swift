import CoreGraphics
import Foundation

public enum AnnotationRenderer {
    /// Draws annotations into a context whose user space is image pixels with
    /// a top-left origin (a flipped view, or a bitmap after `flipVertically`).
    /// `source` is the capture, needed by blur, pixelate and the eraser.
    /// Pixel effects (blur, pixelate, eraser) belong to the picture, so they
    /// go under every vector mark regardless of the order they were added.
    public static func draw(_ annotations: [Annotation], in context: CGContext, source: CGImage?) {
        for annotation in annotations where annotation.isPixelEffect { draw(annotation, in: context, source: source) }
        for annotation in annotations where !annotation.isPixelEffect { draw(annotation, in: context, source: source) }
    }

    public static func draw(_ annotation: Annotation, in context: CGContext, source: CGImage?) {
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
        case let .ellipse(rect):
            context.strokeEllipse(in: rect)
        case let .highlight(rect):
            context.setBlendMode(.multiply)
            context.setFillColor(style.color.withAlpha(0.45).cgColor)
            context.fill(rect)
        case let .text(origin, string):
            TextLayout(string: string, fontSize: style.fontSize, color: style.color.cgColor).draw(at: origin, in: context)
        case let .step(center, number):
            drawStep(number, at: center, style: style, in: context)
        case let .blur(rect):
            drawEffect(.blur, rect, strength: max(style.lineWidth * 1.5, 6), source: source, in: context)
        case let .pixelate(rect):
            drawEffect(.pixelate, rect, strength: max(style.lineWidth * 2.5, 8), source: source, in: context)
        case let .erase(rect):
            drawEffect(.erase, rect, strength: 0, source: source, in: context)
        }
    }

    private static func drawEffect(_ kind: ImageEffects.Kind, _ rect: CGRect, strength: CGFloat, source: CGImage?, in context: CGContext) {
        guard let source, let patch = ImageEffects.patch(kind, of: source, in: rect, strength: strength) else { return }
        let target = rect.pixelAligned.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        context.interpolationQuality = .none
        context.drawImageTopLeft(patch, in: target)
    }

    private static func drawStep(_ number: Int, at center: CGPoint, style: AnnotationStyle, in context: CGContext) {
        let r = style.stepRadius
        let circle = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        context.setShadow(offset: CGSize(width: 0, height: -r * 0.08), blur: r * 0.25, color: CGColor(gray: 0, alpha: 0.35))
        context.fillEllipse(in: circle)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(max(r * 0.12, 1.5))
        context.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
        let luminance = 0.299 * style.color.red + 0.587 * style.color.green + 0.114 * style.color.blue
        let textColor = luminance > 0.7 ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
        let layout = TextLayout(string: "\(number)", fontSize: r * (number > 9 ? 0.95 : 1.15), color: textColor)
        layout.draw(at: CGPoint(x: center.x - layout.size.width / 2, y: center.y - layout.size.height / 2), in: context)
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

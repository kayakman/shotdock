import CoreGraphics
import Foundation

public enum AnnotationRenderer {
    /// Draws annotations into a context whose user space is image pixels with
    /// a top-left origin (a flipped view, or a bitmap after `flipVertically`).
    /// `source` is the capture, needed by blur, pixelate and the eraser.
    /// Pixel effects (blur, pixelate, eraser) belong to the picture, so they
    /// go under every vector mark regardless of the order they were added.
    public static func draw(_ annotations: [Annotation], in context: CGContext, source: CGImage?) {
        let effects = annotations.filter(\.isPixelEffect)
        for annotation in effects { draw(annotation, in: context, source: source) }
        for annotation in annotations where !annotation.isPixelEffect { draw(annotation, in: context, source: source, effects: effects) }
    }

    /// `effects` are the pixel effects of the document: a magnifier shows the
    /// picture with them applied, so it never reveals what was blurred.
    public static func draw(_ annotation: Annotation, in context: CGContext, source: CGImage?, effects: [Annotation] = []) {
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
        case let .magnifier(sourceRect, target, round):
            drawMagnifier(sourceRect, target, round: round, style: style, image: source, effects: effects, in: context)
        }
    }

    private static func drawMagnifier(_ sourceRect: CGRect, _ target: CGRect, round: Bool, style: AnnotationStyle,
                                      image: CGImage?, effects: [Annotation], in context: CGContext) {
        let thin = max(style.lineWidth * 0.4, 1.5)
        let outline: (CGRect) -> CGPath = { rect in
            round ? CGPath(ellipseIn: rect, transform: nil)
                  : CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height) * 0.06,
                           cornerHeight: min(rect.width, rect.height) * 0.06, transform: nil)
        }

        // Connector between the shapes' centres, kept outside both so it never covers the source.
        context.saveGState()
        context.addRect(sourceRect.union(target).insetBy(dx: -thin * 4, dy: -thin * 4))
        context.addPath(outline(sourceRect))
        context.addPath(outline(target))
        context.clip(using: .evenOdd)
        context.setLineWidth(thin)
        context.setLineDash(phase: 0, lengths: [thin * 3, thin * 2])
        context.strokeLineSegments(between: [CGPoint(x: sourceRect.midX, y: sourceRect.midY), CGPoint(x: target.midX, y: target.midY)])
        context.restoreGState()
        context.setLineWidth(max(style.lineWidth * 0.6, 2))
        context.addPath(outline(sourceRect))
        context.strokePath()

        // The enlargement, with a shadow behind it.
        context.saveGState()
        let shadowOffset = context.convertToDeviceSpace(CGSize(width: 0, height: style.lineWidth))
        let blur = context.convertToDeviceSpace(CGSize(width: style.lineWidth * 3, height: 0))
        context.setShadow(offset: shadowOffset, blur: hypot(blur.width, blur.height), color: CGColor(gray: 0, alpha: 0.4))
        context.addPath(outline(target))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()

        if let image, let region = composite(image, effects: effects, region: sourceRect) {
            context.saveGState()
            context.addPath(outline(target))
            context.clip()
            // Big zooms show the pixels as squares, small ones stay smooth.
            context.interpolationQuality = target.width / max(sourceRect.width, 1) >= 3 ? .none : .high
            context.drawImageTopLeft(region, in: target)
            context.restoreGState()
        }
        context.setLineWidth(style.lineWidth)
        context.addPath(outline(target))
        context.strokePath()
    }

    /// The picture inside `region` with the pixel effects that touch it.
    static func composite(_ image: CGImage, effects: [Annotation], region: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = region.pixelAligned.intersection(bounds)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let touching = effects.filter { $0.bounds.intersects(rect) }
        guard !touching.isEmpty else { return image.cropping(to: rect) }
        guard let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.flipVertically(height: rect.height)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.drawImageTopLeft(image, in: bounds)
        for effect in touching { draw(effect, in: context, source: image) }
        return context.makeImage()
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

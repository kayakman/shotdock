import CoreGraphics
import Foundation

/// A capture being edited: the untouched pixels plus everything drawn on top.
/// Cropping is non-destructive so it can be undone and annotations keep their
/// coordinates.
public struct CaptureDocument {
    public var image: CGImage
    /// Pixels per point of the display it came from (2 on Retina).
    public var scale: CGFloat
    public var annotations: [Annotation] = []
    public var crop: CGRect?
    /// Frame for sharing; nil exports the capture alone.
    public var backdrop: Backdrop?
    /// Export size as a fraction of the drawn size (0.5 halves it); nil keeps it.
    /// Like the crop, it only applies when exporting.
    public var resize: CGFloat?
    public var createdAt: Date

    /// Number for the next step marker.
    public var nextStepNumber: Int {
        (annotations.compactMap { if case let .step(_, n) = $0.shape { n } else { nil } }.max() ?? 0) + 1
    }

    public init(image: CGImage, scale: CGFloat, createdAt: Date = Date()) {
        self.image = image
        self.scale = scale
        self.createdAt = createdAt
    }

    public var fullRect: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    /// The part of the image that is exported.
    public var visibleRect: CGRect { (crop ?? fullRect).intersection(fullRect).pixelAligned }

    /// What is drawn: the capture area and, with a backdrop, the canvas around it.
    public var layout: (canvas: CGRect, content: CGRect) {
        backdrop?.layout(content: visibleRect, scale: scale) ?? (visibleRect, visibleRect)
    }

    /// Size of the exported image in pixels.
    public var outputSize: CGSize {
        let canvas = layout.canvas.size
        let factor = resize ?? 1
        return CGSize(width: max(1, (canvas.width * factor).rounded()), height: max(1, (canvas.height * factor).rounded()))
    }

    /// Pixels per point of the exported image: resizing changes the pixel
    /// density, not the size it shows at (a halved Retina capture is 1×).
    public var exportScale: CGFloat { scale * (resize ?? 1) }

    /// Draws the document into a top-left-origin context in image pixels.
    public func draw(in context: CGContext, annotationsFilter: (Annotation) -> Bool = { _ in true }) {
        let (canvas, content) = layout
        context.saveGState()
        if let backdrop {
            backdrop.drawBackground(canvas: canvas, content: content, scale: scale, in: context)
            context.addPath(backdrop.contentPath(content, scale: scale))
            context.clip()
        } else {
            context.clip(to: content)
        }
        context.drawImageTopLeft(image, in: fullRect)
        AnnotationRenderer.draw(annotations.filter(annotationsFilter), in: context, source: image)
        context.restoreGState()
    }

    /// The final image: annotations burned in, the crop applied, the backdrop
    /// around it and resized.
    public func flattened() -> CGImage? {
        let rect = layout.canvas
        let size = outputSize
        guard rect.width >= 1, rect.height >= 1,
              let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.flipVertically(height: size.height)
        // Drawn scaled rather than scaled afterwards: marks and text stay sharp.
        context.scaleBy(x: size.width / rect.width, y: size.height / rect.height)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        draw(in: context)
        return context.makeImage()
    }

    /// The resize factor that gives `width` or `height` pixels (keeping the
    /// proportions), or nil when neither is given.
    public func resizeFactor(width: Double?, height: Double?) -> CGFloat? {
        let canvas = layout.canvas.size
        if let width, width > 0 { return width / canvas.width }
        if let height, height > 0 { return height / canvas.height }
        return nil
    }
}

public extension CGContext {
    /// Draws an image upright in a top-left-origin context.
    func drawImageTopLeft(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}

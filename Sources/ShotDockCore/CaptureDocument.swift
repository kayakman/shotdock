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

    /// The final image: annotations burned in and the crop applied.
    public func flattened() -> CGImage? {
        let rect = visibleRect
        guard rect.width >= 1, rect.height >= 1,
              let context = CGContext(
                data: nil, width: Int(rect.width), height: Int(rect.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.flipVertically(height: rect.height)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.drawImageTopLeft(image, in: fullRect)
        AnnotationRenderer.draw(annotations, in: context, source: image)
        return context.makeImage()
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

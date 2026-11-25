import CoreGraphics
import Foundation

/// A frame for sharing: the capture on a gradient or solid background, with
/// margin, rounded corners and a drop shadow (Shottr's "backdrop").
public struct Backdrop: Codable, Equatable, Sendable {
    public enum Fill: Codable, Equatable, Sendable {
        /// Two colours; `angle` in degrees, 0 = left to right, 90 = top to bottom.
        case gradient(RGBAColor, RGBAColor, angle: Double)
        case solid(RGBAColor)
    }

    public enum Aspect: String, CaseIterable, Codable, Sendable {
        case auto, square, wide, standard, portrait

        /// Width ÷ height, or nil to follow the capture.
        public var ratio: CGFloat? {
            switch self {
            case .auto: nil
            case .square: 1
            case .wide: 16.0 / 9.0
            case .standard: 4.0 / 3.0
            case .portrait: 4.0 / 5.0
            }
        }

        public var title: String {
            switch self {
            case .auto: "Automática"
            case .square: "1:1"
            case .wide: "16:9"
            case .standard: "4:3"
            case .portrait: "4:5"
            }
        }
    }

    public var fill: Fill
    /// Margin around the capture, in points (scaled by the capture's scale).
    public var padding: CGFloat
    /// Corner radius of the capture, in points.
    public var cornerRadius: CGFloat
    /// Shadow strength, 0…1.
    public var shadow: CGFloat
    public var aspect: Aspect

    public init(fill: Fill = Backdrop.presets[0], padding: CGFloat = 48, cornerRadius: CGFloat = 10,
                shadow: CGFloat = 0.5, aspect: Aspect = .auto) {
        self.fill = fill
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.aspect = aspect
    }

    public static let presets: [Fill] = [
        .gradient(RGBAColor(red: 1.0, green: 0.55, blue: 0.24), RGBAColor(red: 0.93, green: 0.22, blue: 0.43), angle: 45),  // sunset
        .gradient(RGBAColor(red: 0.36, green: 0.42, blue: 0.98), RGBAColor(red: 0.73, green: 0.36, blue: 0.96), angle: 45),  // violet
        .gradient(RGBAColor(red: 0.13, green: 0.75, blue: 0.80), RGBAColor(red: 0.18, green: 0.42, blue: 0.94), angle: 45),  // ocean
        .gradient(RGBAColor(red: 0.55, green: 0.86, blue: 0.47), RGBAColor(red: 0.13, green: 0.63, blue: 0.52), angle: 45),  // mint
        .gradient(RGBAColor(red: 0.99, green: 0.84, blue: 0.40), RGBAColor(red: 0.98, green: 0.52, blue: 0.27), angle: 45),  // sun
        .gradient(RGBAColor(red: 0.18, green: 0.19, blue: 0.22), RGBAColor(red: 0.04, green: 0.05, blue: 0.06), angle: 90),  // graphite
        .gradient(RGBAColor(red: 0.95, green: 0.95, blue: 0.97), RGBAColor(red: 0.84, green: 0.86, blue: 0.90), angle: 90),  // silver
        .solid(RGBAColor(red: 1, green: 0.353, blue: 0.122)),                                                                // ShotDock orange
    ]

    /// Where the background and the capture go, in the capture's pixel
    /// coordinates: the capture keeps its rect and the canvas grows around it.
    public func layout(content: CGRect, scale: CGFloat) -> (canvas: CGRect, content: CGRect) {
        let margin = (padding * scale).rounded()
        var canvas = content.insetBy(dx: -margin, dy: -margin)
        if let ratio = aspect.ratio {
            if canvas.width / canvas.height < ratio {
                let width = (canvas.height * ratio).rounded()
                canvas = CGRect(x: canvas.minX - ((width - canvas.width) / 2).rounded(.down), y: canvas.minY,
                                width: width, height: canvas.height)
            } else {
                let height = (canvas.width / ratio).rounded()
                canvas = CGRect(x: canvas.minX, y: canvas.minY - ((height - canvas.height) / 2).rounded(.down),
                                width: canvas.width, height: height)
            }
        }
        return (canvas, content)
    }

    /// Paints the background and the capture's shadow. The caller then clips
    /// to `contentPath` and draws the capture. Top-left-origin context.
    public func drawBackground(canvas: CGRect, content: CGRect, scale: CGFloat, in context: CGContext) {
        context.saveGState()
        switch fill {
        case let .solid(color):
            context.setFillColor(color.cgColor)
            context.fill(canvas)
        case let .gradient(from, to, angle):
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [from.cgColor, to.cgColor] as CFArray,
                                      locations: [0, 1])!
            let radians = angle * .pi / 180
            let dx = cos(radians), dy = sin(radians)
            // Endpoints on the line through the centre so the gradient spans the whole canvas.
            let half = (abs(dx) * canvas.width + abs(dy) * canvas.height) / 2
            let center = CGPoint(x: canvas.midX, y: canvas.midY)
            context.clip(to: canvas)
            context.drawLinearGradient(gradient, start: CGPoint(x: center.x - dx * half, y: center.y - dy * half),
                                       end: CGPoint(x: center.x + dx * half, y: center.y + dy * half), options: [])
        }
        context.restoreGState()

        if shadow > 0 {
            context.saveGState()
            // Shadow geometry is in device space and ignores the CTM, so convert
            // "10 pt down" and the blur radius from user space.
            let offset = context.convertToDeviceSpace(CGSize(width: 0, height: 10 * scale * shadow))
            let blur = context.convertToDeviceSpace(CGSize(width: 28 * scale * shadow, height: 0))
            context.setShadow(offset: offset, blur: hypot(blur.width, blur.height),
                              color: CGColor(gray: 0, alpha: 0.25 + 0.35 * shadow))
            context.addPath(contentPath(content, scale: scale))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
    }

    public func contentPath(_ content: CGRect, scale: CGFloat) -> CGPath {
        let radius = min(cornerRadius * scale, content.width / 2, content.height / 2)
        return CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

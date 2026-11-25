import CoreGraphics
import CoreImage
import Foundation

/// Pixel effects that read the capture under an annotation: blur, pixelate
/// and the smart eraser. Results are cached per image and rectangle because
/// the editor redraws them on every mouse move.
public enum ImageEffects {
    public enum Kind: Int, Sendable { case blur, pixelate, erase }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    nonisolated(unsafe) private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        return cache
    }()

    /// The replacement pixels for `rect` (image pixels, top-left origin), or
    /// nil if the rectangle is outside the image.
    public static func patch(_ kind: Kind, of image: CGImage, in rect: CGRect, strength: CGFloat) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = rect.pixelAligned.intersection(bounds)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let key = "\(ObjectIdentifier(image).hashValue)|\(kind.rawValue)|\(rect)|\(strength)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let result: CGImage? = switch kind {
        case .blur: blurred(image, rect, radius: strength)
        case .pixelate: pixelated(image, rect, blockSize: strength)
        case .erase: SmartFill.fill(image, rect)
        }
        if let result { cache.setObject(result, forKey: key) }
        return result
    }

    private static func ciRect(_ rect: CGRect, in image: CGImage) -> CGRect {
        // Core Image has a bottom-left origin.
        CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func blurred(_ image: CGImage, _ rect: CGRect, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let region = ciRect(rect, in: image)
        // Blur a margin around the area too so its edges are as blurred as its centre.
        let source = input.cropped(to: region.insetBy(dx: -radius * 3, dy: -radius * 3)).clampedToExtent()
        let output = source.applyingGaussianBlur(sigma: radius)
        return context.createCGImage(output, from: region)
    }

    private static func pixelated(_ image: CGImage, _ rect: CGRect, blockSize: CGFloat) -> CGImage? {
        let region = ciRect(rect, in: image)
        let source = CIImage(cgImage: image).cropped(to: region).clampedToExtent()
        let filter = CIFilter(name: "CIPixellate", parameters: [
            kCIInputImageKey: source,
            kCIInputScaleKey: max(blockSize, 2),
            kCIInputCenterKey: CIVector(x: region.minX, y: region.maxY),  // blocks start at the top-left corner
        ])
        guard let output = filter?.outputImage else { return nil }
        return context.createCGImage(output, from: region)
    }
}

/// The smart eraser: fills a rectangle with what surrounds it. The four
/// edges just outside the area are sampled, smoothed so stray text or icons
/// crossing them do not show, and blended across the area (a Coons patch),
/// which reproduces flat backgrounds and gradients.
public enum SmartFill {
    public static func fill(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        let width = Int(rect.width), height = Int(rect.height)
        guard width > 0, height > 0 else { return nil }
        // Read the area plus a 2 px border, clamped to the image.
        let border = 2
        let outer = rect.insetBy(dx: -CGFloat(border), dy: -CGFloat(border))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = PixelBuffer(image: image, rect: outer) else { return nil }
        let ox = Int(rect.minX - outer.minX), oy = Int(rect.minY - outer.minY)
        let hasTop = oy > 0, hasLeft = ox > 0
        let hasBottom = oy + height < pixels.height, hasRight = ox + width < pixels.width

        func edge(count: Int, available: Bool, sample: (Int) -> SIMD4<Float>) -> [SIMD4<Float>]? {
            available ? smooth((0..<count).map(sample)) : nil
        }
        // Average of the two rows/columns just outside each side.
        let top = edge(count: width, available: hasTop) { x in
            pixels.average(ox + x, max(oy - 1, 0), ox + x, max(oy - 2, 0))
        }
        let bottom = edge(count: width, available: hasBottom) { x in
            pixels.average(ox + x, min(oy + height, pixels.height - 1), ox + x, min(oy + height + 1, pixels.height - 1))
        }
        let left = edge(count: height, available: hasLeft) { y in
            pixels.average(max(ox - 1, 0), oy + y, max(ox - 2, 0), oy + y)
        }
        let right = edge(count: height, available: hasRight) { y in
            pixels.average(min(ox + width, pixels.width - 1), oy + y, min(ox + width + 1, pixels.width - 1), oy + y)
        }
        // A missing side (area touching the image edge) borrows its opposite.
        guard let t = top ?? bottom ?? left.map({ resample($0, to: width) }) ?? right.map({ resample($0, to: width) }) else {
            return nil
        }
        let b = bottom ?? t
        let l = left ?? right ?? resample([t.first!, b.first!], to: height)
        let r = right ?? l

        var output = [UInt8](repeating: 255, count: width * height * 4)
        let tl = (t[0] + l[0]) / 2, tr = (t[width - 1] + r[0]) / 2
        let bl = (b[0] + l[height - 1]) / 2, br = (b[width - 1] + r[height - 1]) / 2
        let w = Float(max(width - 1, 1)), h = Float(max(height - 1, 1))
        for y in 0..<height {
            let v = Float(y) / h
            for x in 0..<width {
                let u = Float(x) / w
                var c = (1 - v) * t[x] + v * b[x] + (1 - u) * l[y] + u * r[y]
                c -= (1 - u) * (1 - v) * tl + u * (1 - v) * tr + (1 - u) * v * bl + u * v * br
                let i = (y * width + x) * 4
                output[i] = UInt8(max(0, min(255, c.x.rounded())))
                output[i + 1] = UInt8(max(0, min(255, c.y.rounded())))
                output[i + 2] = UInt8(max(0, min(255, c.z.rounded())))
                output[i + 3] = UInt8(max(0, min(255, c.w.rounded())))
            }
        }
        return PixelBuffer.makeImage(rgba: output, width: width, height: height)
    }

    /// Cleans one edge: samples that do not follow the edge's overall trend
    /// (text or an icon the rectangle cuts through) are replaced by a robust
    /// straight-line fit, then the rest is median-filtered and softened.
    static func smooth(_ values: [SIMD4<Float>]) -> [SIMD4<Float>] {
        let n = values.count
        guard n > 2 else { return values }
        var inlier = [Bool](repeating: true, count: n)
        // Start from the median, which a minority of intruders cannot drag.
        let middle = n / 2
        var fit: (SIMD4<Float>, SIMD4<Float>) = (SIMD4(
            values.map(\.x).sorted()[middle], values.map(\.y).sorted()[middle],
            values.map(\.z).sorted()[middle], values.map(\.w).sorted()[middle]), .zero)
        for iteration in 0..<5 {
            if iteration > 0 { fit = lineFit(values, inlier) }
            let residuals = (0..<n).map { i -> Float in
                let d = values[i] - (fit.0 + fit.1 * Float(i))
                return max(abs(d.x), abs(d.y), abs(d.z), abs(d.w))
            }
            let inlierResiduals = (0..<n).filter { inlier[$0] }.map { residuals[$0] }.sorted()
            let mad = inlierResiduals.isEmpty ? 0 : inlierResiduals[inlierResiduals.count / 2]
            let threshold = max(3 * 1.4826 * mad, 10)
            let next = residuals.map { $0 <= threshold }
            if next.filter({ $0 }).count < max(n / 3, 2) || (iteration > 0 && next == inlier) { break }
            inlier = next
        }
        if inlier.contains(true) { fit = lineFit(values, inlier) }
        let cleaned = (0..<n).map { inlier[$0] ? values[$0] : fit.0 + fit.1 * Float($0) }
        return medianAndBox(cleaned)
    }

    /// Least-squares line per channel over the inlier samples: value ≈ a + b·i.
    static func lineFit(_ values: [SIMD4<Float>], _ inlier: [Bool]) -> (SIMD4<Float>, SIMD4<Float>) {
        var count: Float = 0, sumX: Float = 0, sumXX: Float = 0
        var sumY = SIMD4<Float>.zero, sumXY = SIMD4<Float>.zero
        for (i, v) in values.enumerated() where inlier[i] {
            let x = Float(i)
            count += 1; sumX += x; sumXX += x * x; sumY += v; sumXY += v * x
        }
        guard count > 0 else { return (values[0], .zero) }
        let denominator = count * sumXX - sumX * sumX
        guard abs(denominator) > 1e-6 else { return (sumY / count, .zero) }
        let b = (count * sumXY - sumX * sumY) / denominator
        let a = (sumY - b * sumX) / count
        return (a, b)
    }

    static func medianAndBox(_ values: [SIMD4<Float>]) -> [SIMD4<Float>] {
        let n = values.count
        guard n > 2 else { return values }
        let medianRadius = min(max(n / 12, 2), 12)
        var median = values
        for i in 0..<n {
            let window = values[max(0, i - medianRadius)...min(n - 1, i + medianRadius)]
            median[i] = SIMD4(
                window.map(\.x).sorted()[window.count / 2], window.map(\.y).sorted()[window.count / 2],
                window.map(\.z).sorted()[window.count / 2], window.map(\.w).sorted()[window.count / 2])
        }
        let boxRadius = min(max(n / 20, 1), 16)
        var prefix = [SIMD4<Float>](repeating: .zero, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + median[i] }
        return (0..<n).map { i in
            let lo = max(0, i - boxRadius), hi = min(n - 1, i + boxRadius)
            return (prefix[hi + 1] - prefix[lo]) / Float(hi - lo + 1)
        }
    }

    static func resample(_ values: [SIMD4<Float>], to count: Int) -> [SIMD4<Float>] {
        guard values.count > 1, count > 1 else { return [SIMD4<Float>](repeating: values.first ?? .zero, count: max(count, 1)) }
        return (0..<count).map { i in
            let position = Float(i) / Float(count - 1) * Float(values.count - 1)
            let lower = Int(position), upper = min(lower + 1, values.count - 1)
            let f = position - Float(lower)
            return values[lower] * (1 - f) + values[upper] * f
        }
    }
}

/// RGBA8 pixels of part of an image, row 0 at the top.
struct PixelBuffer {
    let width: Int
    let height: Int
    private var bytes: [UInt8]

    init?(image: CGImage, rect: CGRect) {
        guard let cropped = image.cropping(to: rect) else { return nil }
        width = cropped.width
        height = cropped.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
    }

    func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return SIMD4(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2]), Float(bytes[i + 3]))
    }

    func average(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> SIMD4<Float> {
        (pixel(x1, y1) + pixel(x2, y2)) / 2
    }

    static func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

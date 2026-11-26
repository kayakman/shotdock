import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ShotDockCore

/// An image from a function giving the RGBA of each pixel.
private func image(_ width: Int, _ height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b, a) = pixel(x, y)
            // Premultiplied, as CGContext wants.
            let i = (y * width + x) * 4
            bytes[i] = UInt8(Int(r) * Int(a) / 255); bytes[i + 1] = UInt8(Int(g) * Int(a) / 255)
            bytes[i + 2] = UInt8(Int(b) * Int(a) / 255); bytes[i + 3] = a
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

/// Encodes, decodes with ImageIO and returns how far the pixels are from the original.
private func roundTrip(_ original: CGImage) throws -> (maxDifference: Int, bytes: Int) {
    let data = try WebPLossless.encode(original)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == "org.webmproject.webp")
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.width == original.width && decoded.height == original.height)
    let a = rgba(original), b = rgba(decoded)
    return (zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0, data.count)
}

@Test func webpTinyImages() throws {
    #expect(try roundTrip(image(1, 1) { _, _ in (255, 90, 31, 255) }).maxDifference == 0)
    #expect(try roundTrip(image(3, 2) { x, y in (UInt8(x * 80), UInt8(y * 200), 7, 255) }).maxDifference == 0)
}

@Test func webpPalettesWithPacking() throws {
    // 2, 4, 16 and 200 colours: 8, 4, 2 and 1 pixels per packed pixel; odd widths.
    for colours in [2, 4, 16, 200] {
        let picture = image(37, 23) { x, y in
            let c = (x * 7 + y * 3) % colours
            return (UInt8(c), UInt8(255 - c), UInt8((c * 37) & 0xFF), 255)
        }
        let result = try roundTrip(picture)
        #expect(result.maxDifference == 0, "\(colours) colours")
    }
}

@Test func webpPredictorPathOnManyColours() throws {
    // A smooth gradient (predictors shine) and noise (nothing to predict).
    let gradient = image(301, 97) { x, y in (UInt8(x % 256), UInt8(y * 2), UInt8((x + y) % 256), 255) }
    #expect(try roundTrip(gradient).maxDifference == 0)
    var seed: UInt32 = 12345
    func next() -> UInt8 { seed = seed &* 1_103_515_245 &+ 12345; return UInt8((seed >> 16) & 0xFF) }
    let noise = image(64, 50) { _, _ in (next(), next(), next(), 255) }
    #expect(try roundTrip(noise).maxDifference == 0)
}

@Test func webpKeepsTransparency() throws {
    let picture = image(40, 30) { x, y in (200, 100, UInt8(x * 6), UInt8(x < 10 ? 0 : y * 8)) }
    // Premultiplied round trips lose a little precision at low alpha, nothing more.
    #expect(try roundTrip(picture).maxDifference <= 1)
}

@Test func webpCompressesScreenshotsBetterThanPNG() throws {
    // A UI-like image: flat panels, lines and repeated rows.
    let picture = image(1200, 800) { x, y in
        if y < 60 { return (240, 240, 245, 255) }
        if x < 220 { return (y % 40 < 30 ? 230 : 210, 232, 236, 255) }
        if (x / 120 + y / 90) % 2 == 0, y % 90 > 20, x % 120 > 15 { return (255, 255, 255, 255) }
        return (x % 120 == 0 || y % 90 == 0 ? 180 : 250, 250, 252, 255)
    }
    let result = try roundTrip(picture)
    let png = try ImageEncoding.data(from: picture, format: .png)
    #expect(result.maxDifference == 0)
    #expect(result.bytes < png.count, "WebP \(result.bytes) B vs PNG \(png.count) B")
}

@Test func webpRealisticMixOfManyColours() throws {
    // More than 256 colours with structure: the predictor path with long matches.
    let picture = image(640, 360) { x, y in
        let band = (y / 30) % 3
        return (UInt8((x * 255) / 640), UInt8(band == 0 ? 40 : 200), UInt8((y * 255) / 360), 255)
    }
    let result = try roundTrip(picture)
    #expect(result.maxDifference == 0)
    let png = try ImageEncoding.data(from: picture, format: .png)
    #expect(result.bytes < png.count, "WebP \(result.bytes) B vs PNG \(png.count) B")
}

@Test func webpRefusesTooLargeImages() {
    let tall = image(1, 1) { _, _ in (0, 0, 0, 255) }
    #expect(throws: Never.self) { _ = try WebPLossless.encode(tall) }
    let profile = ExportProfile(name: "Web", format: .webp)
    #expect(profile.writtenFormat(for: CGSize(width: 800, height: 20000)) == .png)
    #expect(profile.writtenFormat(for: CGSize(width: 800, height: 2000)) == .webp)
}

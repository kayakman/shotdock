import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

func makeImage(width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat) = (1, 0, 0)) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Test func pngRoundTripKeepsSize() throws {
    let data = try ImageEncoding.data(from: makeImage(width: 40, height: 30), scale: 2)
    let decoded = try ImageEncoding.image(from: data)
    #expect(decoded.width == 40)
    #expect(decoded.height == 30)
}

@Test func jpegEncodes() throws {
    let data = try ImageEncoding.data(from: makeImage(width: 10, height: 10), format: .jpeg)
    #expect(data.starts(with: [0xFF, 0xD8]))
}

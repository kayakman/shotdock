import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

/// White image with a 40 × 20 orange box at (30, 10).
private func boxImage() -> CGImage {
    let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.flipVertically(height: 50)
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
    context.setFillColor(red: 1, green: 90.0 / 255, blue: 31.0 / 255, alpha: 1)
    context.fill(CGRect(x: 30, y: 10, width: 40, height: 20))
    return context.makeImage()!
}

@Test func rulerMeasuresTheBoxUnderThePointer() throws {
    let m = try #require(Measure.edges(in: boxImage(), at: CGPoint(x: 45.5, y: 20.2)))
    #expect(m.width == 40 && m.height == 20)
    #expect(m.rect(around: CGPoint(x: 45.5, y: 20.2)) == CGRect(x: 30, y: 10, width: 40, height: 20))
}

@Test func rulerMeasuresTheGapToTheImageEdge() throws {
    let m = try #require(Measure.edges(in: boxImage(), at: CGPoint(x: 10, y: 20)))
    #expect(m.left == 10 && m.width == 30)   // from the left edge to the box
    #expect(m.height == 50)                  // the white column runs the full height
    #expect(Measure.edges(in: boxImage(), at: CGPoint(x: 100, y: 0)) == nil)
}

@Test func pickerReadsColourAndFormats() throws {
    let color = try #require(Measure.color(in: boxImage(), at: CGPoint(x: 31, y: 11)))
    #expect(ColorFormat.hex.string(for: color) == "#FF5A1F")
    #expect(ColorFormat.rgb.string(for: color) == "rgb(255, 90, 31)")
}

import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

@Test func backdropAddsMarginAndKeepsContent() throws {
    var document = CaptureDocument(image: makeImage(width: 400, height: 200, color: (1, 1, 1)), scale: 2)
    document.backdrop = Backdrop(fill: .solid(.blue), padding: 20, cornerRadius: 0, shadow: 0)
    let output = try #require(document.flattened())
    #expect(output.width == 400 + 80 && output.height == 200 + 80)   // 20 pt × 2 on each side
    #expect(pixel(output, 5, 5).b > 200 && pixel(output, 5, 5).r < 50)  // background
    #expect(isWhite(pixel(output, 240, 140)))                            // capture
}

@Test func roundedCornersShowTheBackground() throws {
    var document = CaptureDocument(image: makeImage(width: 400, height: 200, color: (1, 1, 1)), scale: 1)
    document.backdrop = Backdrop(fill: .solid(.black), padding: 10, cornerRadius: 30, shadow: 0)
    let output = try #require(document.flattened())
    #expect(pixel(output, 12, 12).r < 30)    // just inside the capture's corner: rounded away
    #expect(isWhite(pixel(output, 60, 60)))
}

@Test func aspectRatioWidensTheCanvas() throws {
    var document = CaptureDocument(image: makeImage(width: 300, height: 300), scale: 1)
    document.backdrop = Backdrop(padding: 0, aspect: .wide)
    let output = try #require(document.flattened())
    #expect(output.height == 300 && output.width == 533)
}

@Test func annotationsAndCropWorkInsideTheBackdrop() throws {
    var document = CaptureDocument(image: makeImage(width: 400, height: 400, color: (1, 1, 1)), scale: 1)
    document.crop = CGRect(x: 100, y: 100, width: 200, height: 200)
    document.annotations = [Annotation(shape: .rectangle(CGRect(x: 120, y: 120, width: 100, height: 100)), style: AnnotationStyle(color: .red, lineWidth: 6))]
    document.backdrop = Backdrop(fill: .solid(.black), padding: 30, cornerRadius: 0, shadow: 0)
    let output = try #require(document.flattened())
    #expect(output.width == 260)
    #expect(isReddish(pixel(output, 30 + 20, 30 + 60)))   // rectangle's left edge at x = 120 → 20 px into the crop
    #expect(pixel(output, 10, 10).r < 30)
}

@Test func gradientShadowRender() throws {
    var document = CaptureDocument(image: makeImage(width: 200, height: 100, color: (1, 1, 1)), scale: 1)
    document.backdrop = Backdrop(fill: Backdrop.presets[0], padding: 40, cornerRadius: 8, shadow: 1)
    let output = try #require(document.flattened())
    let left = pixel(output, 2, 2), right = pixel(output, 277, 177)
    #expect(left != right, "gradient varies across the canvas")
    // The shadow darkens the background just below the capture.
    let below = pixel(output, 140, 40 + 100 + 8), far = pixel(output, 140, 178)
    #expect(Int(below.r) + Int(below.g) < Int(far.r) + Int(far.g))
}

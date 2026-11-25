import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

/// White 400 × 300 image with a 20 × 20 red square at (40, 40).
private func imageWithSquare() -> CGImage {
    let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.flipVertically(height: 300)
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 40, y: 40, width: 20, height: 20))
    return context.makeImage()!
}

private let style = AnnotationStyle(color: .blue, lineWidth: 4)

@Test func magnifierShowsTheSourceEnlarged() throws {
    var document = CaptureDocument(image: imageWithSquare(), scale: 1)
    // Source (30…70) holds the red square at 40…60; shown 4× at (200, 100).
    document.annotations = [Annotation(shape: .magnifier(source: CGRect(x: 30, y: 30, width: 40, height: 40),
                                                         target: CGRect(x: 200, y: 100, width: 160, height: 160), round: false), style: style)]
    let output = try #require(document.flattened())
    #expect(isReddish(pixel(output, 280, 180)), "centre of the enlargement is the red square")
    #expect(isWhite(pixel(output, 215, 115)), "its margin is the white around the square")
    #expect(isReddish(pixel(output, 50, 50)), "the original stays as it was")
}

@Test func roundMagnifierClipsCorners() throws {
    var document = CaptureDocument(image: makeImage(width: 400, height: 300, color: (1, 0, 0)), scale: 1)
    document.annotations = [Annotation(shape: .magnifier(source: CGRect(x: 10, y: 10, width: 40, height: 40),
                                                         target: CGRect(x: 200, y: 100, width: 160, height: 160), round: true), style: style)]
    let output = try #require(document.flattened())
    #expect(isReddish(pixel(output, 280, 180)))
    let corner = pixel(output, 204, 104)  // inside the target rect, outside the circle: the original red, not the border
    #expect(isReddish(corner), "\(corner)")
}

@Test func magnifierDoesNotRevealBlurredContent() throws {
    var document = CaptureDocument(image: imageWithSquare(), scale: 1)
    document.annotations = [
        Annotation(shape: .pixelate(CGRect(x: 30, y: 30, width: 40, height: 40)), style: AnnotationStyle(lineWidth: 12)),
        Annotation(shape: .magnifier(source: CGRect(x: 30, y: 30, width: 40, height: 40),
                                     target: CGRect(x: 200, y: 100, width: 160, height: 160), round: false), style: style),
    ]
    let output = try #require(document.flattened())
    // With 30 px blocks the square's edge at x = 40 is gone: both sides of it look the same, enlarged.
    let outside = pixel(output, 200 + (35 - 30) * 4, 100 + (45 - 30) * 4)
    let inside = pixel(output, 200 + (45 - 30) * 4, 100 + (45 - 30) * 4)
    #expect(outside == inside, "\(outside) vs \(inside)")
}

@Test func magnifierPlacementPartsAndHandles() {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    let m = Annotation.magnifier(source: CGRect(x: 20, y: 100, width: 50, height: 40), round: true, within: bounds, gap: 10, style: style)
    guard case let .magnifier(source, target, _) = m.shape else { Issue.record("not a magnifier"); return }
    #expect(target.size == CGSize(width: 100, height: 80) && target.minX == 80, "placed 2× to the right: \(target)")
    #expect(bounds.contains(target))
    #expect(m.magnifierPart(at: CGPoint(x: 130, y: 120)) == .target)
    #expect(m.magnifierPart(at: CGPoint(x: 21, y: 101)) == .source)
    if case let .magnifier(s2, t2, _) = m.movingPart(.target, dx: 50, dy: 0).shape { #expect(s2 == source && t2.minX == 130) }
    // Bigger enlargement from its bottom-right corner keeps the aspect ratio.
    if case let .magnifier(_, t3, _) = m.movingHandle(2, to: CGPoint(x: 230, y: 999)).shape {
        #expect(t3.width == 150 && t3.height == 120 && t3.minX == 80)
    }
    // Near a right edge it goes to the left instead.
    let left = Annotation.magnifier(source: CGRect(x: 330, y: 100, width: 50, height: 40), round: true, within: bounds, gap: 10, style: style)
    if case let .magnifier(_, t4, _) = left.shape { #expect(t4.maxX <= 320) }
}

import CoreGraphics
import Foundation
import Testing
@testable import ShotDockCore

/// Vertical gradient from black (top) to white (bottom) with a red bar in the middle.
private func gradientWithBar() -> CGImage {
    let w = 200, h = 200
    let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.flipVertically(height: CGFloat(h))
    for y in 0..<h {
        let g = CGFloat(y) / CGFloat(h - 1)
        context.setFillColor(red: g, green: g, blue: g, alpha: 1)
        context.fill(CGRect(x: 0, y: y, width: w, height: 1))
    }
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 80, y: 90, width: 40, height: 20))
    return context.makeImage()!
}

private func gray(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Int { Int(p.g) }

@Test func smartEraserFollowsTheGradient() throws {
    var document = CaptureDocument(image: gradientWithBar(), scale: 1)
    document.annotations = [Annotation(shape: .erase(CGRect(x: 70, y: 80, width: 60, height: 40)), style: AnnotationStyle())]
    let output = try #require(document.flattened())
    let center = pixel(output, 100, 100)
    #expect(abs(Int(center.r) - Int(center.g)) < 6, "red bar is gone: \(center)")
    // Rows keep their gradient value inside the erased area.
    for y in [82, 100, 118] {
        let expected = Int((Double(y) / 199 * 255).rounded())
        #expect(abs(gray(pixel(output, 100, y)) - expected) <= 4, "row \(y): \(pixel(output, 100, y)) vs \(expected)")
    }
}

@Test func smartEraserAtImageEdge() throws {
    let white = makeImage(width: 100, height: 100, color: (1, 1, 1))
    var document = CaptureDocument(image: white, scale: 1)
    document.annotations = [Annotation(shape: .erase(CGRect(x: 0, y: 0, width: 30, height: 30)), style: AnnotationStyle())]
    let output = try #require(document.flattened())
    #expect(isWhite(pixel(output, 5, 5)))
}

@Test func blurOnlyChangesItsArea() throws {
    var document = CaptureDocument(image: gradientWithBar(), scale: 1)
    document.annotations = [Annotation(shape: .blur(CGRect(x: 70, y: 80, width: 60, height: 40)), style: AnnotationStyle(lineWidth: 6))]
    let output = try #require(document.flattened())
    let edge = pixel(output, 82, 100)  // was solid red, now mixed with the gray around it
    #expect(edge.g > 40 && edge.r < 250, "blurred: \(edge)")
    #expect(pixel(output, 100, 30) == pixel(gradientWithBar(), 100, 30))
}

@Test func pixelateMakesBlocks() throws {
    var document = CaptureDocument(image: gradientWithBar(), scale: 1)
    document.annotations = [Annotation(shape: .pixelate(CGRect(x: 0, y: 0, width: 100, height: 100)), style: AnnotationStyle(lineWidth: 6))]
    let output = try #require(document.flattened())
    // Inside one 15 px block the gradient is flat.
    #expect(gray(pixel(output, 2, 2)) == gray(pixel(output, 2, 12)))
    #expect(gray(pixel(output, 2, 2)) != gray(pixel(output, 2, 40)))
}

@Test func ellipseAndHighlight() throws {
    var document = CaptureDocument(image: makeImage(width: 200, height: 100, color: (1, 1, 1)), scale: 1)
    document.annotations = [
        Annotation(shape: .ellipse(CGRect(x: 10, y: 10, width: 80, height: 80)), style: AnnotationStyle(color: .red, lineWidth: 4)),
        Annotation(shape: .highlight(CGRect(x: 120, y: 10, width: 60, height: 60)), style: AnnotationStyle(color: .yellow)),
    ]
    let output = try #require(document.flattened())
    #expect(isReddish(pixel(output, 50, 10)))     // top of the ellipse
    #expect(isWhite(pixel(output, 50, 50)))       // centre stays clear
    #expect(isWhite(pixel(output, 12, 12)))       // bounding-box corner is outside the ellipse
    let marked = pixel(output, 150, 40)
    #expect(marked.r > 240 && marked.b < 200, "yellow marker: \(marked)")
}

@Test func stepsNumberThemselves() throws {
    var document = CaptureDocument(image: makeImage(width: 100, height: 100, color: (1, 1, 1)), scale: 1)
    #expect(document.nextStepNumber == 1)
    document.annotations = [Annotation(shape: .step(center: CGPoint(x: 50, y: 50), number: 1), style: AnnotationStyle(color: .blue, fontSize: 30))]
    #expect(document.nextStepNumber == 2)
    let output = try #require(document.flattened())
    let edge = pixel(output, 50, 50 - 16)
    #expect(edge.b > 200 && edge.r < 100, "blue disc: \(edge)")
}

@Test func resizeHandles() {
    let rect = Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 50, height: 30)), style: AnnotationStyle())
    #expect(rect.handles.count == 4)
    // Dragging the bottom-right corner keeps the top-left fixed.
    #expect(rect.movingHandle(2, to: CGPoint(x: 100, y: 80)).box == CGRect(x: 10, y: 10, width: 90, height: 70))
    // Dragging past the opposite corner flips the box instead of going negative.
    #expect(rect.movingHandle(0, to: CGPoint(x: 80, y: 60)).box == CGRect(x: 60, y: 40, width: 20, height: 20))
    let arrow = Annotation(shape: .arrow(from: .zero, to: CGPoint(x: 10, y: 0)), style: AnnotationStyle())
    #expect(arrow.movingHandle(1, to: CGPoint(x: 5, y: 5)).shape == .arrow(from: .zero, to: CGPoint(x: 5, y: 5)))
    let ellipse = Annotation(shape: .ellipse(CGRect(x: 0, y: 0, width: 100, height: 50)), style: AnnotationStyle(lineWidth: 4))
    #expect(ellipse.hitTest(CGPoint(x: 50, y: 1)))
    #expect(!ellipse.hitTest(CGPoint(x: 50, y: 25)))
}

@Test func smartEraserIgnoresTextCrossingAnEdge() throws {
    // White page with a black "text" bar that the erased area cuts through on its left edge.
    let w = 200, h = 100
    let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.flipVertically(height: CGFloat(h))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 20, y: 40, width: 120, height: 20))
    var document = CaptureDocument(image: context.makeImage()!, scale: 1)
    document.annotations = [Annotation(shape: .erase(CGRect(x: 60, y: 20, width: 100, height: 60)), style: AnnotationStyle())]
    let output = try #require(document.flattened())
    for x in [62, 100, 150] {
        #expect(gray(pixel(output, x, 50)) > 235, "x \(x): \(pixel(output, x, 50))")
    }
}

@Test func effectsDrawUnderVectorMarks() throws {
    var document = CaptureDocument(image: makeImage(width: 100, height: 100, color: (1, 1, 1)), scale: 1)
    document.annotations = [
        Annotation(shape: .rectangle(CGRect(x: 20, y: 20, width: 60, height: 60)), style: AnnotationStyle(color: .red, lineWidth: 6)),
        Annotation(shape: .erase(CGRect(x: 0, y: 0, width: 100, height: 50)), style: AnnotationStyle()),
    ]
    let output = try #require(document.flattened())
    #expect(isReddish(pixel(output, 50, 20)), "rectangle stays above the eraser added after it")
}
